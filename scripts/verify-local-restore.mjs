import { access, readFile } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";

const markerName = ".carrierflow-disposable-restore";
const markerValue = "carrierflow-disposable-restore-v1\n";
const metadataFormat = "carrierflow-local-restore-dry-run-v1";

function fail(message) {
  throw new Error(message);
}

function parseArguments(argumentsList) {
  const values = new Map();

  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--dry-run") {
      values.set(argument, true);
      continue;
    }
    if (argument === "--directory" || argument === "--metadata") {
      const value = argumentsList[index + 1];
      if (!value || value.startsWith("--")) fail(`Missing value for ${argument}.`);
      values.set(argument, value);
      index += 1;
      continue;
    }
    fail(`Unsupported argument: ${argument}.`);
  }

  if (values.get("--dry-run") !== true) fail("Only --dry-run is supported; this script never restores data.");
  const directory = values.get("--directory");
  const metadata = values.get("--metadata");
  if (typeof directory !== "string" || !isAbsolute(directory)) {
    fail("--directory must be an explicit absolute disposable directory.");
  }
  if (typeof metadata !== "string" || !isAbsolute(metadata)) {
    fail("--metadata must be an explicit absolute path inside that disposable directory.");
  }
  return { directory, metadata };
}

function metadataIsInsideDirectory(directory, metadata) {
  const relativePath = relative(directory, metadata);
  return relativePath !== "" && !relativePath.startsWith("..") && !isAbsolute(relativePath);
}

function validateMetadata(value) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail("Restore metadata must be an object.");
  }
  const metadata = value;
  if (
    metadata.format !== metadataFormat ||
    metadata.source !== "disposable-local-test" ||
    typeof metadata.backupId !== "string" ||
    !/^[A-Za-z0-9._-]{1,80}$/.test(metadata.backupId) ||
    metadata.encrypted !== true ||
    typeof metadata.createdAt !== "string" ||
    Number.isNaN(new Date(metadata.createdAt).getTime())
  ) {
    fail("Restore metadata is not an approved local dry-run fixture.");
  }
  return metadata;
}

export async function verifyLocalRestoreDryRun(argumentsList = process.argv.slice(2)) {
  const { directory, metadata: metadataPath } = parseArguments(argumentsList);
  const resolvedDirectory = resolve(directory);
  const resolvedMetadata = resolve(metadataPath);

  if (!metadataIsInsideDirectory(resolvedDirectory, resolvedMetadata)) {
    fail("--metadata must remain inside the explicit disposable directory.");
  }
  if (!resolvedDirectory.split(/[\\/]/).at(-1)?.startsWith("carrierflow-restore-dry-run-")) {
    fail("Disposable directory must begin with carrierflow-restore-dry-run-.");
  }

  await access(resolvedDirectory);
  const marker = await readFile(resolve(resolvedDirectory, markerName), "utf8");
  if (marker !== markerValue) fail("Disposable restore marker is missing or invalid.");

  const metadata = validateMetadata(JSON.parse(await readFile(resolvedMetadata, "utf8")));
  process.stdout.write(
    [
      "LOCAL RESTORE DRY RUN ONLY",
      `Validated local fixture metadata: ${metadata.backupId}`,
      "No database, object storage, network, or container restore was performed.",
      "This does not verify an off-server backup or a production restore.",
    ].join("\n") + "\n",
  );
}

if (import.meta.main) {
  verifyLocalRestoreDryRun().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Restore dry-run failed."}\n`);
    process.exitCode = 1;
  });
}
