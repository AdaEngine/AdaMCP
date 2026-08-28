import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export function defaultProfilesDirectory() {
  return process.platform === "darwin"
    ? path.join(os.homedir(), "Library", "Application Support", "AdaMCP", "profiles")
    : path.join(os.homedir(), ".adamcp", "profiles");
}

export class ProfilerSessionStore {
  constructor(directory = defaultProfilesDirectory()) {
    this.directory = directory;
  }

  async save(capture, target = null) {
    const id = capture?.manifest?.id;
    validateSessionID(id);
    const directory = path.join(this.directory, id);
    await fs.mkdir(directory, { recursive: true });
    const manifest = { ...capture.manifest, target };
    await Promise.all([
      fs.writeFile(path.join(directory, "manifest.json"), JSON.stringify(manifest, null, 2)),
      fs.writeFile(path.join(directory, "capture.json"), JSON.stringify({ ...capture, manifest }, null, 2)),
      fs.writeFile(path.join(directory, "events.json"), JSON.stringify(capture.spans ?? [], null, 2)),
      fs.writeFile(path.join(directory, "summary.json"), JSON.stringify(capture.summary ?? {}, null, 2)),
      fs.writeFile(path.join(directory, "trace.json"), JSON.stringify(capture.trace ?? { traceEvents: [] }))
    ]);
    return { ...capture, manifest };
  }

  async list() {
    let entries;
    try {
      entries = await fs.readdir(this.directory, { withFileTypes: true });
    } catch (error) {
      if (error.code === "ENOENT") {
        return [];
      }
      throw error;
    }
    const manifests = await Promise.all(entries.filter((entry) => entry.isDirectory()).map(async (entry) => {
      try {
        return JSON.parse(await fs.readFile(path.join(this.directory, entry.name, "manifest.json"), "utf8"));
      } catch {
        return null;
      }
    }));
    return manifests.filter(Boolean).sort((lhs, rhs) => String(rhs.startedAt).localeCompare(String(lhs.startedAt)));
  }

  async get(id) {
    validateSessionID(id);
    try {
      return JSON.parse(await fs.readFile(path.join(this.directory, id, "capture.json"), "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") {
        return null;
      }
      throw error;
    }
  }

  async trace(id) {
    validateSessionID(id);
    try {
      return JSON.parse(await fs.readFile(path.join(this.directory, id, "trace.json"), "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") {
        return null;
      }
      throw error;
    }
  }

  async remove(id) {
    validateSessionID(id);
    await fs.rm(path.join(this.directory, id), { recursive: true, force: true });
  }
}

function validateSessionID(id) {
  if (typeof id !== "string" || !/^[a-zA-Z0-9-]+$/.test(id)) {
    throw new Error("Invalid profiler session id.");
  }
}
