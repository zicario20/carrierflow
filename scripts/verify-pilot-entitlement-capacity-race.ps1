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

function Invoke-PilotCapacitySql {
  param([Parameter(Mandatory)][string]$Sql)

  $output = $Sql | & docker exec -i $dbContainer psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ($output -join [Environment]::NewLine)
  }
  return ($output -join [Environment]::NewLine).Trim()
}

$companyId = '33333333-3333-4333-8333-333333333331'
$ownerId = '77777777-7777-4777-8777-777777777731'
$ownerMembershipId = '88888888-8888-4888-8888-888888888831'
$firstCandidateUserId = '99999999-9999-4999-8999-999999999931'
$secondCandidateUserId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31'
$firstCandidateMembershipId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb31'
$secondCandidateMembershipId = 'cccccccc-cccc-4ccc-8ccc-cccccccccc31'
$firstWorker = $null
$secondWorker = $null
$verificationFailure = $null

try {
  Invoke-PilotCapacitySql @"
begin;
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('$ownerId'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pilot-capacity-race-owner@carrierflow.test', '\$2a\$10\$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('$firstCandidateUserId'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pilot-capacity-race-one@carrierflow.test', '\$2a\$10\$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('$secondCandidateUserId'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pilot-capacity-race-two@carrierflow.test', '\$2a\$10\$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));
insert into public.companies (id, name) values ('$companyId'::uuid, 'Pilot capacity race carrier');
insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('$ownerMembershipId'::uuid, '$companyId'::uuid, '$ownerId'::uuid, 'owner', 'active'),
  ('$firstCandidateMembershipId'::uuid, '$companyId'::uuid, '$firstCandidateUserId'::uuid, 'driver', 'active'),
  ('$secondCandidateMembershipId'::uuid, '$companyId'::uuid, '$secondCandidateUserId'::uuid, 'driver', 'active');
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select
  ('50000000-0000-4000-8000-' || lpad(candidate::text, 12, '0'))::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated',
  format('pilot-capacity-race-existing-%s@carrierflow.test', candidate), '\$2a\$10\$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
from generate_series(1, 9) as candidate;
insert into public.company_memberships (id, company_id, user_id, role, status)
select
  ('60000000-0000-4000-8000-' || lpad(candidate::text, 12, '0'))::uuid,
  '$companyId'::uuid,
  ('50000000-0000-4000-8000-' || lpad(candidate::text, 12, '0'))::uuid,
  'driver', 'active'
from generate_series(1, 9) as candidate;
insert into public.drivers (company_id, membership_id, display_name)
select
  '$companyId'::uuid,
  ('60000000-0000-4000-8000-' || lpad(candidate::text, 12, '0'))::uuid,
  format('Existing pilot driver %s', candidate)
from generate_series(1, 9) as candidate;
commit;
"@ | Out-Null

  $firstSql = @"
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$ownerId', true);
select public.create_driver('$companyId'::uuid, '$firstCandidateMembershipId'::uuid, 'Concurrent candidate one');
select pg_sleep(1);
commit;
"@
  $secondSql = @"
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$ownerId', true);
select public.create_driver('$companyId'::uuid, '$secondCandidateMembershipId'::uuid, 'Concurrent candidate two');
commit;
"@
  $worker = {
    param($container, $sql)
    $result = $sql | & docker exec -i $container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At 2>&1
    if ($LASTEXITCODE -ne 0) {
      $message = $result -join [Environment]::NewLine
      if ($message -match 'the active driver capacity has been reached') {
        return 'capacity_denied'
      }
      throw $message
    }
    return 'activated'
  }
  $firstWorker = Start-Job -ScriptBlock $worker -ArgumentList $dbContainer, $firstSql
  Start-Sleep -Milliseconds 150
  $secondWorker = Start-Job -ScriptBlock $worker -ArgumentList $dbContainer, $secondSql
  Wait-Job -Job $firstWorker, $secondWorker -Timeout 15 | Out-Null
  if ($firstWorker.State -ne 'Completed' -or $secondWorker.State -ne 'Completed') {
    $states = "first=$($firstWorker.State); second=$($secondWorker.State)"
    $details = @(
      $firstWorker, $secondWorker | Receive-Job -Keep -ErrorAction SilentlyContinue 2>&1
    ) -join [Environment]::NewLine
    throw "The pilot entitlement capacity workers did not complete within 15 seconds ($states). Output: $details"
  }
  $outcomes = @($firstWorker, $secondWorker | Receive-Job -ErrorAction Stop)
  if ((@($outcomes | Where-Object { $_ -eq 'activated' }).Count -ne 1) -or (@($outcomes | Where-Object { $_ -eq 'capacity_denied' }).Count -ne 1)) {
    throw "Expected one activation and one capacity denial; received '$($outcomes -join ',')'."
  }

  $activeDriverCount = Invoke-PilotCapacitySql "select count(*) from public.drivers where company_id = '$companyId'::uuid and status = 'active';"
  $candidateDriverCount = Invoke-PilotCapacitySql "select count(*) from public.drivers where company_id = '$companyId'::uuid and membership_id in ('$firstCandidateMembershipId'::uuid, '$secondCandidateMembershipId'::uuid);"
  if ($activeDriverCount -ne '10' -or $candidateDriverCount -ne '1') {
    throw "Expected capacity-safe race result of 10 active / 1 candidate profile; received '$activeDriverCount' / '$candidateDriverCount'."
  }
  Write-Output 'Pilot entitlement two-session capacity race passed: one activation, one denial, and ten active drivers.'
}
catch {
  $verificationFailure = $_
}
finally {
  $workers = @($firstWorker, $secondWorker | Where-Object { $null -ne $_ })
  if ($workers.Count -gt 0) {
    Remove-Job -Job $workers -Force -ErrorAction SilentlyContinue
  }
  $cleanupFailure = $null
  try {
    Invoke-PilotCapacitySql @"
begin;
delete from public.company_privacy_retention_runs where company_id = '$companyId'::uuid;
delete from public.current_driver_locations where company_id = '$companyId'::uuid;
delete from public.driver_location_history where company_id = '$companyId'::uuid;
delete from public.driver_location_daily_rollups where company_id = '$companyId'::uuid;
alter table public.audit_events disable trigger audit_events_immutable;
delete from public.audit_events where company_id = '$companyId'::uuid;
alter table public.audit_events enable trigger audit_events_immutable;
delete from public.drivers where company_id = '$companyId'::uuid;
delete from public.company_memberships where company_id = '$companyId'::uuid;
delete from public.companies where id = '$companyId'::uuid;
delete from auth.users where id in (
  '$ownerId'::uuid, '$firstCandidateUserId'::uuid, '$secondCandidateUserId'::uuid
) or id::text like '50000000-0000-4000-8000-%';
commit;
"@ | Out-Null
  }
  catch {
    $cleanupFailure = $_
  }

  if ($null -ne $verificationFailure) {
    if ($null -ne $cleanupFailure) {
      throw "Pilot entitlement capacity race failed: $($verificationFailure.Exception.Message)`nFixture cleanup also failed: $($cleanupFailure.Exception.Message)"
    }
    throw $verificationFailure
  }
  if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
  }
}
