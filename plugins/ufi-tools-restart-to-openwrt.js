//<script>
// 插件名：重启到 OpenWrt
// 版本：1.0
// 作者：Mavis（为 ZTE V50 / MU3351 定制）
// 仓库：本地自制，未发布
// 设备：ZTE V50（MU3351）—— Android 13 + mu300-linux（OpenWrt 25.12.5）双系统
//
// 依赖：Magisk 模块 mu300_linux_switch（提供 switch.sh，装机脚本会自动安装）
//
// 本插件是「一键操作」型，不是「装软件」型：不下载、不解压、不写开机自启。
// 因此 HARD-RULES 第 5/6/7/8 条（下载 / 写配置 / 自启 / 卸载）不适用；
// 第 1/2/3/4/9 条已全部满足。
//
// 原理：mu300-linux 的 Linux 系统是「一次性试用」——
//   switch.sh 只改 misc 分区偏移 0x800 的 32 字节（AOSP bootloader_control，priority/tries + CRC32），
//   LK 于是启动一次 boot_b 上的 Linux；Linux 起来后会自己把这 32 字节改回 Android，
//   所以之后任何重启都会回 Android。也就是说每次进 Linux 都要从 Android 再切一次——这正是本插件存在的理由。
//   本插件不碰 boot_a / GPT / userdata；Linux 起不来会自动回 Android。
(async () => {
  // ---------- 常量 ----------
  const MOD_DIR      = '/data/adb/modules/mu300_linux_switch';
  const SWITCH_SH    = `${MOD_DIR}/switch.sh`;
  const MOD_DISABLED = `${MOD_DIR}/disable`;
  const LOG_FILE     = '/data/local/tmp/mu300-switch.log';
  const MODAL_NAME   = 'mu300_switch_to_openwrt';

  // ---------- 工具 ----------
  // 读文件一律走 `timeout 2s awk`（HARD-RULES 第 4 条：cat 在 UFI-TOOLS 上易乱码且可能阻塞）
  const readFile = async (p) => {
    const r = await runShellWithRoot(`timeout 2s awk '{print}' ${p}`);
    return r?.success ? (r.content || '').trim() : '';
  };

  const exists = async (p) => {
    const r = await runShellWithRoot(`ls ${p}`);
    if (!r?.success) return false;
    return !/No such file|not found|Permission denied/i.test(r.content || '');
  };

  // 「高级功能（root）」检查。utils.js 正常会注入 checkAdvancedFunc；
  // 万一某个版本里没有它，直接看能不能拿到 root——不要因为一个函数名就让整个插件点不动。
  const ensureAdvanced = async () => {
    try {
      if (typeof checkAdvancedFunc === 'function') return Boolean(await checkAdvancedFunc());
    } catch (_) { /* 落到底下的兜底判断 */ }
    const r = await runShellWithRoot('id -u');
    return (r?.content || '').trim() === '0';
  };

  // ---------- 状态探测 ----------
  // 判据全部来自 switch.sh 自己的输出，不自己猜字面量：
  //   正常 -> "boot_b         the Linux boot image"
  //   异常 -> 它的 die 文案（"no Linux is installed" / "not a boot image" / "another boot image"）
  const probeState = async () => {
    const s = { haveModule: false, moduleDisabled: false, ok: false, reason: '', statusText: '' };

    s.haveModule = await exists(SWITCH_SH);
    if (!s.haveModule) {
      s.reason = `未找到切换模块：${SWITCH_SH} 不存在。请先安装 mu300-linux（其 Magisk 装机脚本会带上这个模块）。`;
      return s;
    }
    s.moduleDisabled = await exists(MOD_DISABLED);

    const res = await runShellWithRoot(`sh ${SWITCH_SH} status`);
    s.statusText = (res?.content || '').trim();

    if (/the Linux boot image/.test(s.statusText)) {
      s.ok = true;
    } else if (/no Linux is installed|a copy of Android/i.test(s.statusText)) {
      s.reason = 'Linux 槽位里是 Android 的副本 —— 还没有装 Linux 系统。';
    } else if (/not a boot image/i.test(s.statusText)) {
      s.reason = 'Linux 槽位不是可引导镜像。';
    } else if (/another boot image/i.test(s.statusText)) {
      s.reason = 'Linux 槽位是别的镜像（既不是 Linux，也不是当前这份 Android）。';
    } else {
      s.reason = '无法识别 Linux 槽位状态，switch.sh 的输出见下方。';
    }
    return s;
  };

  // ---------- 5 连点确认（危险操作：会重启设备）----------
  const create5ConfirmHandler = (actionName, realHandler, needCount = 5, resetMs = 6000) => {
    let count = 0;
    let timer = null;
    return async () => {
      if (!(await ensureAdvanced())) return createToast('请先启用高级功能', 'pink');

      count++;
      timer && clearTimeout(timer);
      const left = needCount - count;

      if (left > 0) {
        createToast(`【${actionName}】会重启设备！还需再点 ${left} 次确认`, 'pink');
        timer = setTimeout(() => { count = 0; }, resetMs);
        return;
      }
      count = 0;
      timer = null;
      return realHandler();
    };
  };

  // ---------- 真正的动作 ----------
  let cooling = false;
  const doSwitch = async () => {
    if (cooling) return createToast('正在切换中，请勿重复点击', 'pink');
    cooling = true;
    try {
      createToast('正在校验并写入引导标志…', '', 4000);

      // 先 --dry-run：不写任何东西，但会走完整套前置校验（misc 魔数、镜像是否 Linux）
      const dry = await runShellWithRoot(`sh ${SWITCH_SH} --dry-run`, 30000);
      const out = (dry?.content || '').trim();

      if (!/dry run: nothing was written/.test(out)) {
        // 没跑到最后一行 = 中途 die 了；把它自己的原话回显给用户，不要自己翻译
        const tail = (out.split('\n').filter((l) => l.trim()).slice(-3).join('<br>') || '（无输出）');
        createToast(`校验未通过，已中止：<br>${tail}`, 'red', 8000);
        return;
      }

      // 真正执行。脚本末尾会 sleep 3 后 reboot，所以放后台跑，
      // 否则 runShellWithRoot 要一直等到设备重启（响应永远回不来）。
      // 输出留档到 LOG_FILE，重启前可以随时看。
      await runShellWithRoot(`sh -c 'sh ${SWITCH_SH} > ${LOG_FILE} 2>&1' >/dev/null 2>&1 &`, 15000);

      createToast('已写入引导标志，设备将在数秒内重启进入 OpenWrt…', 'green', 8000);
      closeModal(`#${MODAL_NAME}`, 300);
    } catch (e) {
      createToast('操作异常：' + (e?.message || e), 'red', 8000);
    } finally {
      setTimeout(() => { cooling = false; }, 5000);
    }
  };

  // ---------- 模块被停用时的一键修复 ----------
  // 模块目录里若存在 disable 文件，Magisk 会把它当停用：mu300-linux 不在 PATH、面板的 Action 按钮也不出现。
  // 改名（不是删除）即可恢复，完全可逆。
  const fixModule = async () => {
    if (!(await ensureAdvanced())) return createToast('请先启用高级功能', 'pink');
    createToast('正在启用切换模块…');
    await runShellWithRoot(`mv ${MOD_DISABLED} ${MOD_DISABLED}.off`);
    const still = await exists(MOD_DISABLED);
    createToast(still ? '启用失败，请手动检查模块目录' : '模块已启用，请重启设备使其生效', still ? 'red' : 'green', 6000);
    await refresh();
  };

  // ---------- 刷新界面 ----------
  const refresh = async () => {
    const box = document.querySelector(`#${MODAL_NAME}_body`);
    if (!box) return;
    box.innerHTML = '<div style="font-size:.72rem;opacity:.7;">检测中…</div>';

    const s = await probeState();
    const okColor = s.ok ? 'var(--dark-btn-color-active)' : '#ff6b6b';
    const modLine = !s.haveModule
      ? '<span style="color:#ff6b6b;">未安装</span>'
      : s.moduleDisabled
        ? '<span style="color:#ff6b6b;">已停用</span>'
        : '<span style="color:var(--dark-btn-color-active);">已启用</span>';

    box.innerHTML = `
      <div style="display:flex;flex-direction:column;gap:12px;">
        <div style="padding:10px;border-radius:10px;background:rgba(255,255,255,.04);">
          <div class="title" style="font-size:.78rem;margin-bottom:6px;">当前状态</div>
          <div style="font-size:.72rem;line-height:1.9;">
            <div>当前运行：<b>Android</b>（插件只在 Android 侧可见）</div>
            <div>切换模块：${modLine}</div>
            <div>Linux 槽位：<span style="color:${okColor};">${s.ok ? '已就绪' : '不可切换'}</span></div>
          </div>
          ${s.reason ? `<div style="margin-top:8px;font-size:.68rem;color:#ff6b6b;">${s.reason}</div>` : ''}
          ${s.statusText ? `<div style="margin-top:8px;font-size:.66rem;opacity:.6;white-space:pre-wrap;">${s.statusText.replace(/</g, '&lt;')}</div>` : ''}
        </div>

        <div style="font-size:.68rem;opacity:.7;line-height:1.7;">
          重启后进入 OpenWrt（WiFi <b><你的热点名></b> / 设备 <b>192.168.77.1</b>）。<br>
          只写 misc 的 32 字节，不动 boot_a / GPT / userdata；Linux 起不来会自动回 Android。<br>
          在 OpenWrt 里再点重启会回到 Android —— 想再进 Linux 就再点一次这个按钮。
        </div>

        <div style="display:flex;gap:10px;flex-wrap:wrap;">
          <button id="${MODAL_NAME}_go" ${s.ok ? '' : 'disabled'}
                  style="${s.ok ? '' : 'opacity:.45;cursor:not-allowed;'}">重启到 OpenWrt</button>
          ${s.moduleDisabled ? `<button id="${MODAL_NAME}_fixmod">启用切换模块</button>` : ''}
          <button id="${MODAL_NAME}_recheck">重新检测</button>
        </div>
      </div>`;

    const go = document.querySelector(`#${MODAL_NAME}_go`);
    if (go) go.onclick = create5ConfirmHandler('重启到 OpenWrt', doSwitch);

    const recheck = document.querySelector(`#${MODAL_NAME}_recheck`);
    if (recheck) recheck.onclick = refresh;

    const fixmod = document.querySelector(`#${MODAL_NAME}_fixmod`);
    if (fixmod) fixmod.onclick = fixModule;
  };

  // ---------- 主入口 ----------
  const mainBtn = document.createElement('button');
  mainBtn.textContent = '重启到 OpenWrt';
  mainBtn.onclick = async () => {
    if (!(await ensureAdvanced())) return createToast('请先启用高级功能', 'pink');

    document.querySelector(`#${MODAL_NAME}`)?.remove();
    const { id, el } = createModal({
      name: MODAL_NAME,
      title: '重启到 OpenWrt 系统',
      maxWidth: '440px',
      showConfirm: false,
      onClose: () => true,
      content: `<div id="${MODAL_NAME}_body" style="min-height:60px;"></div>`,
    });
    showModal(id);
    await refresh();
  };

  document.querySelector('.actions-buttons')?.appendChild(mainBtn);
})();
//</script>
