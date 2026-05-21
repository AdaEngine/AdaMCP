import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export function defaultDiscoveryDir(env = process.env) {
  if (env.ADAMCP_DISCOVERY_DIR) {
    return env.ADAMCP_DISCOVERY_DIR;
  }

  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "AdaMCP", "discovery");
  }

  if (env.XDG_RUNTIME_DIR) {
    return path.join(env.XDG_RUNTIME_DIR, "AdaMCP", "discovery");
  }

  return path.join(os.tmpdir(), "AdaMCP", "discovery");
}

export async function scanManifests({ discoveryDir, now = Date.now(), removeStale = true } = {}) {
  const directory = discoveryDir ?? defaultDiscoveryDir();
  let entries;
  try {
    entries = await fs.readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT") {
      return [];
    }
    throw error;
  }

  const manifests = [];
  await Promise.all(entries.map(async (entry) => {
    if (!entry.isFile() || !entry.name.endsWith(".json")) {
      return;
    }

    const filePath = path.join(directory, entry.name);
    let manifest;
    try {
      manifest = JSON.parse(await fs.readFile(filePath, "utf8"));
    } catch {
      if (removeStale) {
        await fs.rm(filePath, { force: true });
      }
      return;
    }

    if (isLiveManifest(manifest, now)) {
      manifests.push(normalizeManifest(manifest));
    } else if (removeStale) {
      await fs.rm(filePath, { force: true });
    }
  }));

  return manifests.sort((lhs, rhs) => {
    const updatedDelta = Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt);
    return updatedDelta === 0 ? lhs.id.localeCompare(rhs.id) : updatedDelta;
  });
}

export function resolveServer(manifests, selector) {
  if (!selector) {
    if (manifests.length === 1) {
      return manifests[0];
    }
    return null;
  }

  const byID = manifests.find((manifest) => manifest.id === selector);
  if (byID) {
    return byID;
  }

  const byName = manifests.filter((manifest) => manifest.serverName === selector);
  if (byName.length === 1) {
    return byName[0];
  }
  if (byName.length > 1) {
    const error = new Error(`Multiple AdaMCP servers named '${selector}' are live; select by id.`);
    error.code = "AMBIGUOUS_SERVER";
    throw error;
  }

  const error = new Error(`AdaMCP server '${selector}' was not found.`);
  error.code = "SERVER_NOT_FOUND";
  throw error;
}

function isLiveManifest(manifest, now) {
  if (!manifest || manifest.schemaVersion !== 1 || !manifest.id || !manifest.endpointURL) {
    return false;
  }
  const updatedAt = Date.parse(manifest.updatedAt);
  if (!Number.isFinite(updatedAt)) {
    return false;
  }
  const ttl = Number(manifest.ttlSeconds);
  return Number.isFinite(ttl) && ttl > 0 && now - updatedAt <= ttl * 1000;
}

function normalizeManifest(manifest) {
  return {
    id: String(manifest.id),
    pid: manifest.pid,
    processName: manifest.processName ?? "",
    serverName: manifest.serverName ?? "",
    serverVersion: manifest.serverVersion ?? "",
    endpointURL: String(manifest.endpointURL),
    startedAt: manifest.startedAt,
    updatedAt: manifest.updatedAt,
    ttlSeconds: Number(manifest.ttlSeconds),
    metadata: manifest.metadata ?? {}
  };
}
