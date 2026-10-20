#!/usr/bin/env node
/**
 * 迅雷网页版 captcha_sign 盐表提取器（离线复算 + md5 插桩）
 *
 * 用途：迅雷前端重新打包后，15 个盐会变，签名立刻失效。本脚本把「重新提取」
 * 变成两步：
 *   1) 用浏览器把 pan.xunlei.com 的前端分片抓到本地目录（见下）
 *   2) node thunder_web_sign_harness.js <分片目录> [base字符串]
 *
 * 原理：前端是 webpack 打包，签名器是一串「加盐 MD5 嵌套」函数。我们在迷你
 * runtime 里加载这些分片，拦截 blueimp-md5（模块 0）的每次调用，把
 * (输入 -> 输出) 全序列打出来 —— 输入里天然带着上一轮结果和本轮盐，
 * 于是整条链一目了然，不需要逐个人肉跟踪混淆函数。
 *
 * 需要哪些分片（浏览器 F12 → Network → JS，或 CDP 存盘）：
 *   - 含 `0:function`（数组形式 chunk）的那个大分片，通常是 app.<hash>.js
 *     —— 模块 0 = blueimp-md5
 *   - utils-initial.<hash>.js  —— 模块 22（导出表）/ 20 / 21（嵌套包装器）
 *   - utils-async.<hash>.js    —— 模块 1643（顶层 GetCaptchaSign）
 *   - service-captcha.<hash>.js、service-device-sign.<hash>.js（可选，验证用）
 * 文件名随意，脚本按内容自动识别（扫 .js，依次 push 进迷你 runtime）。
 *
 * 输出示例（2026-10-20 抓的版本）：
 *   0. in="Xqp0kJBXWhwaTpB6...1792491447693QT5gqd1eSINZe+K" -> 59ec4e1b...
 *   1. in="59ec4e1b...9TafMwqVWgh45hLntDm6HLcOXE"           -> d6a41876...
 *   ...
 *   -> 第 i 条输入 = 上一条输出 + 盐[i]，盐 = 输入去掉前 32 字符
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dir = process.argv[2];
const baseOverride = process.argv[3];
if (!dir || !fs.existsSync(dir)) {
  console.error('用法: node thunder_web_sign_harness.js <分片目录> [base字符串]');
  process.exit(2);
}

// ---- 迷你 webpack runtime ----
const modules = {};
const cache = {};

global.window = global;
global.self = global;
global.document = { createElement: () => ({ setAttribute() {} }) };
// Node 22 的 globalThis.navigator 是只读 getter，严格模式下直接赋值会抛。
Object.defineProperty(global, 'navigator', {
  value: { userAgent: 'Mozilla/5.0' },
  configurable: true,
  writable: true,
});

global.webpackJsonp = {
  push(data) {
    const [, mods] = data;
    if (Array.isArray(mods)) {
      mods.forEach((fn, i) => { if (typeof fn === 'function') modules[i] = fn; });
    } else if (mods && typeof mods === 'object') {
      for (const k of Object.keys(mods)) modules[k] = mods[k];
    }
  },
};

function makeRequire() {
  const req = (id) => {
    if (cache[id]) return cache[id].exports;
    const factory = modules[id];
    if (!factory) {
      // 缺失的模块（babel helper / 浏览器专用）返回空对象即可：
      // 签名链只依赖模块 0 和 20/21/22，不需要它们。
      cache[id] = { i: id, l: true, exports: {} };
      return cache[id].exports;
    }
    const mod = { i: id, l: false, exports: {} };
    cache[id] = mod;
    factory.call(mod.exports, mod, mod.exports, req);
    mod.l = true;
    return mod.exports;
  };
  req.d = (exports, name, getter) => {
    if (!Object.prototype.hasOwnProperty.call(exports, name))
      Object.defineProperty(exports, name, { enumerable: true, get: getter });
  };
  req.r = (exports) => Object.defineProperty(exports, '__esModule', { value: true });
  req.n = (m) => {
    const g = m && m.__esModule ? () => m.default : () => m;
    g.a = g;
    return g;
  };
  req.t = (id) => req(id);
  req.e = (chunkId) => Promise.reject(new Error('chunk load disabled: ' + chunkId));
  req.p = '';
  return req;
}

const req = makeRequire();

const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
// 先加载含模块 0 的大分片：数组形式 chunk 的模块 id 是下标，必须先注册。
files.sort((a, b) => fs.statSync(path.join(dir, b)).size - fs.statSync(path.join(dir, a)).size);
for (const f of files) {
  try {
    vm.runInThisContext(fs.readFileSync(path.join(dir, f), 'utf8'), { filename: f });
  } catch (e) {
    console.error('[skip] ' + f + ': ' + e.message);
  }
}
if (!modules[0]) {
  console.error('找不到模块 0（blueimp-md5）—— 目录里缺少主 app 分片？');
  process.exit(2);
}

// ---- 拦截 md5 ----
const md5orig = req(0);
const trace = [];
cache[0].exports = function (e, t, r) {
  const out = md5orig(e, t, r);
  trace.push({ in: e, out });
  return out;
};
cache[0].l = true;

// ---- 定位签名函数 ----
// 导出名是构建期随机的（pubXXXX），但配置模块 32 里 pan.xunlei.com 那条的
// funName 就是当前版本的签名导出名，从分片文本里直接 grep。
const FUN_NAME = process.env.XL_FUN_NAME || 'pubIHrxR93yM8iZPRb1X2XWnkng0JpG8p3I';

const m22 = req(22);
const signFn = m22[FUN_NAME];
if (typeof signFn !== 'function') {
  console.error('模块 22 里没有导出 ' + FUN_NAME + '；可用导出：');
  console.error(Object.keys(m22).join('\n'));
  process.exit(2);
}

// 默认用 2026-10-20 的黄金对；换版本时传第 2 个参数覆盖。
const CLIENT_ID = process.env.XL_CID || 'Xqp0kJBXWhwaTpB6';
const VERSION = process.env.XL_VER || '1.93.12';
const HOST = process.env.XL_HOST || 'pan.xunlei.com';
const DEVID = process.env.XL_DEVID || '28419a6fe0b7e47c355bbd8a95777fef';
const TS = process.env.XL_TS || '1792491447693';
const EXPECT = process.env.XL_EXPECT || '1.68270948a01b031830b45681bb1da55f';

const base = baseOverride || CLIENT_ID + VERSION + HOST + DEVID + TS;
const raw = signFn(base);

console.log('base       = ' + base);
console.log('sign       = 1.' + raw);
if (EXPECT) console.log('expected   = ' + EXPECT + '  ' + ('1.' + raw === EXPECT ? '[MATCH]' : '[MISMATCH]'));
console.log('--- md5 trace (' + trace.length + ') ---');
trace.forEach((c, i) => {
  const salt = i === 0 ? c.in.slice(base.length) : c.in.slice(32);
  console.log(String(i).padStart(2) + '. salt=' + JSON.stringify(salt) + ' -> ' + c.out);
});
console.log('--- 盐表（直接填进 thunder.zig 的 web_algorithms）---');
console.log(JSON.stringify(trace.map((c, i) => (i === 0 ? c.in.slice(base.length) : c.in.slice(32)))));
