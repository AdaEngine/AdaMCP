import { spawn } from "node:child_process";
import { ProfilerServer } from "./profiler-server.js";
import { AdamcpRouter } from "./router.js";
import { readFrames, writeFrame } from "./stdio.js";

export function parseArgs(argv = process.argv.slice(2), env = process.env) {
  argv = [...argv];
  const options = {
    command: argv[0] === "profiler" ? argv.shift() : "mcp",
    url: env.ADAMCP_URL,
    server: env.ADAMCP_SERVER,
    discoveryDir: env.ADAMCP_DISCOVERY_DIR,
    stdioCommand: env.ADAMCP_STDIO_COMMAND,
    sessionsDir: env.ADAMCP_PROFILES_DIR,
    host: "127.0.0.1",
    port: 0,
    openBrowser: true
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--url") {
      options.url = argv[++index];
    } else if (arg === "--server") {
      options.server = argv[++index];
    } else if (arg === "--discovery-dir") {
      options.discoveryDir = argv[++index];
    } else if (arg === "--stdio-command") {
      options.stdioCommand = argv[++index];
    } else if (arg === "--sessions-dir") {
      options.sessionsDir = argv[++index];
    } else if (arg === "--host") {
      options.host = argv[++index];
    } else if (arg === "--port") {
      options.port = Number(argv[++index]);
    } else if (arg === "--no-open") {
      options.openBrowser = false;
    } else if (arg === "--help" || arg === "-h") {
      options.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

export async function main(argv = process.argv.slice(2), streams = process) {
  const options = parseArgs(argv);
  if (options.help) {
    streams.stdout.write(helpText());
    return;
  }

  if (options.command === "profiler") {
    await runProfiler(options, streams);
    return;
  }

  if (options.stdioCommand) {
    await runChildStdioProxy(options.stdioCommand, streams);
    return;
  }

  const router = new AdamcpRouter(options);
  const shutdown = async () => {
    await router.close();
  };
  process.once("beforeExit", shutdown);
  process.once("SIGINT", async () => {
    await shutdown();
    process.exit(130);
  });
  process.once("SIGTERM", async () => {
    await shutdown();
    process.exit(143);
  });

  for await (const frame of readFrames(streams.stdin)) {
    let request;
    try {
      request = JSON.parse(frame.toString("utf8"));
    } catch {
      writeFrame(streams.stdout, {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: "Parse error" }
      });
      continue;
    }

    const response = await router.handle(request);
    if (response) {
      writeFrame(streams.stdout, response);
    }
  }

  await shutdown();
}

export async function runProfiler(options, streams = process) {
  const profiler = new ProfilerServer(options);
  const address = await profiler.start();
  streams.stdout.write(`AdaMCP Profiler: ${address}\n`);

  const shutdown = async () => {
    await profiler.close();
  };
  process.once("beforeExit", shutdown);
  process.once("SIGINT", async () => {
    await shutdown();
    process.exit(130);
  });
  process.once("SIGTERM", async () => {
    await shutdown();
    process.exit(143);
  });

  if (options.openBrowser && process.platform === "darwin") {
    const child = spawn("open", [address], { detached: true, stdio: "ignore" });
    child.unref();
  }
}

export async function runChildStdioProxy(command, streams = process) {
  const useProcessGroup = process.platform !== "win32";
  const child = spawn(command, {
    shell: true,
    stdio: ["pipe", "pipe", "pipe"],
    detached: useProcessGroup
  });

  streams.stdin.pipe(child.stdin);
  child.stdout.pipe(streams.stdout);
  child.stderr.pipe(streams.stderr);

  const terminateChild = () => {
    if (child.killed) {
      return;
    }
    try {
      if (useProcessGroup) {
        process.kill(-child.pid, "SIGTERM");
      } else {
        child.kill("SIGTERM");
      }
    } catch {
      // The process may have exited between the check and signal.
    }
  };
  process.once("exit", terminateChild);

  await new Promise((resolve, reject) => {
    child.once("error", (error) => {
      process.off("exit", terminateChild);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      process.off("exit", terminateChild);
      if (signal) {
        resolve();
      } else if (code === 0 || code === null) {
        resolve();
      } else {
        reject(new Error(`stdio command exited with code ${code}`));
      }
    });
  });
}

function helpText() {
  return `Usage: adamcp [--url URL] [--server ID_OR_NAME] [--discovery-dir DIR]\n` +
    `       adamcp --stdio-command COMMAND\n` +
    `       adamcp profiler [--host 127.0.0.1] [--port 0] [--no-open] [--sessions-dir DIR]\n\n` +
    `Environment: ADAMCP_URL, ADAMCP_SERVER, ADAMCP_DISCOVERY_DIR, ADAMCP_STDIO_COMMAND, ADAMCP_PROFILES_DIR\n`;
}
