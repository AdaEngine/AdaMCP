#!/usr/bin/env node
import { main } from "../src/cli.js";

main().catch((error) => {
  console.error(`adamcp: ${error?.message ?? error}`);
  process.exitCode = 1;
});
