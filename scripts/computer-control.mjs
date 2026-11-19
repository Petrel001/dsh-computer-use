#!/usr/bin/env node
// DSH Computer Use - 电脑控制插件 CLI 入口。
// 用法: node computer-control.mjs <command> [options]  (--help 查看全部命令)
import { main } from "./lib/cli.mjs";

await main(process.argv.slice(2));
