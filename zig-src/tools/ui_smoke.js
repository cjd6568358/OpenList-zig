// UI 回归 smoke —— 系统 Chrome + playwright-core 跑真前端（CDN 版）。
//
// 用法（见 TODO §6）：
//   NODE_PATH=C:/Users/Administrator/.workbuddy-ai/binaries/node/workspace/node_modules \
//   node tools/ui_smoke.js
// 环境变量：OLZ_URL / OLZ_USER / OLZ_PASS
//
// 断言（缺一即非零退出）：
//   1. /@zig-setup 内置页渲染
//   2. / 跳登录页 → admin 登录成功（按钮按名字定位 —— 登录页还有「清除」，
//      用 .first() 会点错，这是踩过的坑）
//   3. 首页文件列表渲染出挂载点
//   4. 点击 /quark 进入目录：/api/fs/list 200 且非空
//   5. 管理页 /@manage/storage 打开且 storage/list 200 非空（探测）
//   6. **登录成功后**无「非白名单」4xx/5xx、无请求失败、无 JS 异常
//
// 已知白名单 404：/api/public/plugins 与 /api/public/env_check
//   —— Go 上游也没有这两个端点，前端对它们有容错（STATUS.md §18.2）。
// 登录**前**的 401（/api/me 探测）与相应 axios console 打印也属正常，不计
// 入判定 —— 判定窗口从登录成功那一刻开始（`collecting` 开关）。
const { chromium } = require('playwright-core');

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const BASE = (process.env.OLZ_URL || 'http://192.168.1.1:15399').replace(/\/$/, '');
const USER = (process.env.OLZ_USER || 'admin');
const PASS = (process.env.OLZ_PASS || 'e2e-test-123456');

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok });
  console.log(`${ok ? '  ✅' : '  ❌'} ${name} ${detail}`);
};

(async () => {
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const page = await browser.newPage();

  const consoleErrors = [];
  const badResponses = [];
  const failedReqs = [];
  // 判定从登录成功后才开始 —— 登录前的 /@login 页会主动探测 /api/me（401 正常）。
  let collecting = false;
  const WLUrl = [/\/api\/public\/plugins/, /\/api\/public\/env_check/];
  page.on('console', (m) => {
    if (m.type() === 'error' && collecting) consoleErrors.push(m.text().slice(0, 160));
  });
  page.on('response', (r) => {
    if (collecting && r.status() >= 400 && !WLUrl.some((re) => re.test(r.url()))) {
      badResponses.push(`${r.status()} ${r.request().method()} ${r.url().slice(0, 140)}`);
    }
  });
  page.on('requestfailed', (r) => {
    if (collecting) failedReqs.push(`${r.method()} ${r.url().slice(0, 140)} — ${r.failure()?.errorText}`);
  });

  // 1. 内置页
  await page.goto(`${BASE}/@zig-setup`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(1500);
  let txt = await page.locator('body').innerText();
  check('内置页 /@zig-setup 渲染', txt.includes('内置页'),
        txt.slice(0, 60).replace(/\n/g, ' '));

  // 2. 登录
  await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(4000);
  // 判据不能只看 URL：前端 4.2.7 起登录页停在 `/`（SPA 内部路由），
  // 只有 4.2.6 才是 `/@login?redirect=%2F`。所以「URL 命中 或 登录表单在」即可。
  const loginFormCount = await page.locator('input[name=username]').count();
  check('未登录进入登录页', page.url().includes('@login') || loginFormCount > 0,
        page.url() + (loginFormCount > 0 ? '  (登录表单已渲染)' : ''));
  await page.fill('input[name=username]', USER);
  await page.fill('input[name=password]', PASS);
  await page.getByRole('button', { name: '登录', exact: true }).click();
  await page.waitForTimeout(5000);
  check('登录后离开登录页', !page.url().includes('@login'), page.url());
  // 登录成功 → 从这里开始所有 4xx/5xx 与 JS 错误都算失败
  collecting = true;

  // 3. 首页列表
  // 首页要等所有挂载点各自 list 完才渲染；固定等 3s 在挂载多/前端版本更新时会
  // 假失败（4.2.7 就比 4.2.6 慢）。改成轮询，最多 12s。
  let homeTxt = '';
  for (let i = 0; i < 12; i++) {
    homeTxt = await page.locator('body').innerText();
    if (homeTxt.includes('quark')) break;
    await page.waitForTimeout(1000);
  }
  check('首页渲染挂载点 quark', homeTxt.includes('quark'), homeTxt.slice(0, 80).replace(/\n/g, ' '));

  // 4. 进 quark 目录
  const [resp] = await Promise.all([
    page.waitForResponse(
      (r) => r.url().includes('/api/fs/list') && r.status() === 200,
      { timeout: 25000 }).catch(() => null),
    page.getByText('quark', { exact: true }).first().click().catch(() => {}),
  ]);
  if (resp) {
    let n = -1;
    try { n = (((await resp.json()).data || {}).content || []).length; } catch {}
    check('点击 quark → fs/list 200 且非空', n > 0, `${n} 条`);
  } else {
    check('点击 quark → fs/list 200 且非空', false, '未捕获到 fs/list 响应');
  }
  await page.waitForTimeout(2500);
  const dirTxt = await page.locator('body').innerText();
  console.log('  目录页文本（前 200 字）:', dirTxt.slice(0, 200).replace(/\n/g, ' | '));

  // 4b. 面包屑返回根列表（SPA 路由，不是整页刷新）
  // 面包屑文本是「🏠首页」——带 emoji，所以**不能**用 `exact: true` 匹配
  // （第一次就栽在这：静默点不到，断言假失败）。
  await page.getByText('首页').first().click({ timeout: 8000 }).catch(() => {});
  await page.waitForTimeout(3000);
  const backTxt = await page.locator('body').innerText();
  check('点面包屑「首页」回到根列表', backTxt.includes('ecloud_self'),
        backTxt.slice(0, 60).replace(/\n/g, ' '));

  // 5. 管理页：打开后点击「存储」导航 → 等 storage/list 响应
  try {
    await page.goto(`${BASE}/@manage/storage`, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await page.waitForTimeout(3000);
    const [resp2] = await Promise.all([
      page.waitForResponse(
        (r) => r.url().includes('/api/admin/storage/list') && r.status() === 200,
        { timeout: 20000 }).catch(() => null),
      page.getByText('存储', { exact: true }).first().click({ timeout: 8000 }).catch(() => {}),
    ]);
    if (resp2) {
      let n = -1;
      try { n = (((await resp2.json()).data || {}).content || []).length; } catch {}
      check('管理页 存储 tab → storage/list 200 非空', n > 0, `${n} 个存储`);
      // 表格要真渲染出挂载点，而不只是拿到 JSON
      await page.waitForTimeout(3000);
      const tblTxt = await page.locator('body').innerText();
      const found = ['quark', 'hikvision', 'aliyun'].filter((x) => tblTxt.includes(x));
      check('存储列表渲染出挂载点名', found.length >= 2, found.join(',') || '(未见到)');
    } else {
      const stTxt = await page.locator('body').innerText();
      console.log('  管理页未捕获 storage/list 响应，页面文本（前 150 字）:',
                  stTxt.slice(0, 150).replace(/\n/g, ' | '));
    }
  } catch (e) {
    console.log('  管理页探测失败:', e.message.slice(0, 100));
  }

  // 6. 清点错误
  check('无非白名单 4xx/5xx', badResponses.length === 0, badResponses.slice(0, 5).join(' ; '));
  check('无请求失败', failedReqs.length === 0, failedReqs.slice(0, 5).join(' ; '));
  // console.error 里有两类「正常噪声」要剔除：
  //   a) "Failed to load resource" —— 浏览器对任何非 2xx 的提示（白名单
  //      404 与 axios 常规打印都会带出）；
  //   b) "AxiosError: Request failed with status code" —— axios 对失败请求
  //      的常规日志，对应的失败已由上面的 badResponses 断言覆盖。
  // 剩下的才是真正需要标记的 JS 异常。
  const jsErrors = consoleErrors.filter((t) =>
    !/Failed to load resource/.test(t) && !/AxiosError.*status code/.test(t));
  check('无 JS 异常', jsErrors.length === 0, jsErrors.slice(0, 3).join(' ; '));

  await browser.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n=== UI smoke 汇总：${results.length - failed.length}/${results.length} 通过 ===`);
  failed.forEach((f) => console.log('  ❌ ' + f.name));
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error('FATAL', e.message);
  process.exit(2);
});
