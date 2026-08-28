[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectPath = (Get-Location).Path
$dbContainer = @(
  docker ps --filter "label=com.supabase.cli.workdir=$projectPath" --filter 'name=supabase_db' --format '{{.Names}}'
) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($dbContainer)) {
  throw 'A local Supabase database container for this worktree is required. Run `pnpm exec supabase start` first.'
}

function Invoke-RouteRaceSql {
  param([Parameter(Mandatory)][string]$Sql)

  $output = $Sql | & docker exec -i $dbContainer psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ($output -join [Environment]::NewLine)
  }
  return ($output -join [Environment]::NewLine).Trim()
}

$companyId = '33333333-3333-4333-8333-333333333314'
$ownerId = '77777777-7777-4777-8777-777777777714'
$membershipId = '88888888-8888-4888-8888-888888888814'
$requestKey = '14141414-1414-4141-8141-141414141414'
$loadNumber = 'LOCK-RACE-VERIFY'
$updateWorker = $null
$claimWorker = $null
$verificationFailure = $null

try {
  Invoke-RouteRaceSql @"
begin;
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('$ownerId'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'route-lock-verify@carrierflow.test', '\$2a\$10\$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));
insert into public.companies (id, name) values ('$companyId'::uuid, 'Route lock verification carrier');
insert into public.company_memberships (id, company_id, user_id, role, status) values ('$membershipId'::uuid, '$companyId'::uuid, '$ownerId'::uuid, 'owner', 'active');
set local role authenticated;
select set_config('request.jwt.claim.sub', '$ownerId', true);
select public.create_pilot_load('$companyId'::uuid, '$loadNumber', '{"address":"Race pickup","country":"US","timezone":"America/Chicago","latitude":41.8781,"longitude":-87.6298}'::jsonb, '{"address":"Race delivery","country":"US","timezone":"America/Chicago","latitude":42.3314,"longitude":-83.0458}'::jsonb);
select public.set_company_route_base('$companyId'::uuid, '{"label":"Race base","latitude":41.8810,"longitude":-87.6270}'::jsonb);
select public.request_initial_route_estimate('$companyId'::uuid, (select id from public.loads where company_id = '$companyId'::uuid and load_number = '$loadNumber'), 175.00, '$requestKey'::uuid);
commit;
"@ | Out-Null

  $raceRow = Invoke-RouteRaceSql "select load.id || '|' || stop.id || '|' || job.id || '|' || job.idempotency_key from public.loads load join public.load_stops stop on stop.company_id = load.company_id and stop.load_id = load.id join public.route_estimate_recompute_jobs job on job.company_id = load.company_id and job.load_id = load.id where load.company_id = '$companyId'::uuid and load.load_number = '$loadNumber' order by stop.sequence desc limit 1;"
  $loadId, $stopId, $jobId, $jobKey = $raceRow.Split('|')
  if (@($loadId, $stopId, $jobId, $jobKey).Count -ne 4 -or [string]::IsNullOrWhiteSpace($jobKey)) {
    throw 'Unable to resolve the isolated route-estimate job for the concurrency verification.'
  }

  $updateSql = @"
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$ownerId', true);
select public.update_final_planned_stop('$companyId'::uuid, '$loadId'::uuid, '$stopId'::uuid, '{"address":"Race delivery changed","country":"US","timezone":"America/Chicago","latitude":42.4,"longitude":-83.1}'::jsonb);
select pg_sleep(1);
commit;
"@
  $claimSql = @"
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$ownerId', true);
select public.claim_route_estimate_recompute_job('$companyId'::uuid, '$jobId'::uuid, '$jobKey'::uuid);
commit;
"@
  $worker = {
    param($container, $sql)
    $result = $sql | & docker exec -i $container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join [Environment]::NewLine) }
    $result -join [Environment]::NewLine
  }
  $updateWorker = Start-Job -ScriptBlock $worker -ArgumentList $dbContainer, $updateSql
  Start-Sleep -Milliseconds 150
  $claimWorker = Start-Job -ScriptBlock $worker -ArgumentList $dbContainer, $claimSql
  Wait-Job -Job $updateWorker, $claimWorker -Timeout 15 | Out-Null
  if ($updateWorker.State -ne 'Completed' -or $claimWorker.State -ne 'Completed') {
    throw 'The route-estimate concurrency workers did not complete within 15 seconds.'
  }
  $workerOutput = @($updateWorker, $claimWorker | Receive-Job -ErrorAction Stop) -join [Environment]::NewLine
  if ($workerOutput -match '40P01') {
    throw 'The route-estimate lock race produced PostgreSQL deadlock SQLSTATE 40P01.'
  }
  $pendingCount = Invoke-RouteRaceSql "select count(*) from public.route_estimate_recompute_jobs where company_id = '$companyId'::uuid and status = 'pending';"
  if ($pendingCount -ne '1') {
    throw "Expected exactly one pending fresh route-estimate job after the race; received '$pendingCount'."
  }
  Write-Output 'Route-estimate two-session lock race passed: no 40P01 and exactly one fresh pending job.'
}
catch {
  # Preserve the assertion/setup failure while still giving fixture cleanup a
  # chance to run. A cleanup failure is reported alongside it below rather
  # than replacing a deadlock or stale-job regression.
  $verificationFailure = $_
}
finally {
  $workers = @($updateWorker, $claimWorker | Where-Object { $null -ne $_ })
  if ($workers.Count -gt 0) {
    Remove-Job -Job $workers -Force -ErrorAction SilentlyContinue
  }
  $cleanupFailure = $null
  try {
    Invoke-RouteRaceSql @"
begin;
delete from public.driver_incident_receipts where company_id = '$companyId'::uuid;
delete from public.load_dispatch_notifications where company_id = '$companyId'::uuid;
delete from public.load_dispatch_action_receipts where company_id = '$companyId'::uuid;
delete from public.load_assignment_events where company_id = '$companyId'::uuid;
delete from public.load_evidence where company_id = '$companyId'::uuid;
delete from public.load_evidence_requirements where company_id = '$companyId'::uuid;
delete from public.load_incidents where company_id = '$companyId'::uuid;
delete from public.load_proposal_receipts where company_id = '$companyId'::uuid;
delete from public.load_state_events where company_id = '$companyId'::uuid;
delete from public.route_estimate_notifications where company_id = '$companyId'::uuid;
delete from public.route_estimate_context_invalidations where company_id = '$companyId'::uuid;
delete from public.route_estimate_invalidations where company_id = '$companyId'::uuid;
delete from public.route_estimate_heads where company_id = '$companyId'::uuid;
delete from public.route_estimate_recompute_jobs where company_id = '$companyId'::uuid;
delete from public.route_estimate_revisions where company_id = '$companyId'::uuid;
alter table public.audit_events disable trigger audit_events_immutable;
delete from public.audit_events where company_id = '$companyId'::uuid;
alter table public.audit_events enable trigger audit_events_immutable;
delete from public.load_stops where company_id = '$companyId'::uuid;
delete from public.loads where company_id = '$companyId'::uuid;
delete from public.company_route_bases where company_id = '$companyId'::uuid;
delete from public.company_memberships where company_id = '$companyId'::uuid;
delete from public.companies where id = '$companyId'::uuid;
delete from auth.users where id = '$ownerId'::uuid;
commit;
"@ | Out-Null
  }
  catch {
    $cleanupFailure = $_
  }

  if ($null -ne $verificationFailure) {
    if ($null -ne $cleanupFailure) {
      throw "Route-estimate race verification failed: $($verificationFailure.Exception.Message)`nFixture cleanup also failed: $($cleanupFailure.Exception.Message)"
    }
    throw $verificationFailure
  }
  if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
  }
}
