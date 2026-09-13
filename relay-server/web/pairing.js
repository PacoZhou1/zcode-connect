// No fetch, third-party assets, analytics, localStorage or cookies. The credential stays in this page.
(() => {
  const status = document.getElementById('status');
  try {
    const original = new URL(location.href);
    const origin = document.body.dataset.origin;
    const prefix = document.body.dataset.prefix;
    // Remove the QR secret from the visible browser history immediately, including on invalid input.
    history.replaceState(null, '', original.pathname);
    if (original.origin !== origin || original.protocol !== 'https:' || original.username || original.password || original.hash
      || ![`${prefix}/remote/v4`, `${prefix}/remote/v4/`].includes(original.pathname)) throw new Error();
    const allowed = ['sid', 'hash', 't', 'mid', 'name', 'app_version'];
    if ([...original.searchParams.keys()].some((k) => !allowed.includes(k) || original.searchParams.getAll(k).length !== 1)) throw new Error();
    const sid = original.searchParams.get('sid'); const hash = original.searchParams.get('hash');
    if (!sid || sid.length > 256 || !/^[\x21-\x7e]+$/.test(sid)
      || !hash || !/^[A-Za-z0-9+/]{43}=$/.test(hash) || atob(hash).length !== 32 || btoa(atob(hash)) !== hash) throw new Error();
    for (const [key, value] of original.searchParams) if (value.length > 512 || /[\x00-\x1f]/.test(value)) throw new Error();
    const relay = new URL(`${prefix}/ws`, origin); relay.protocol = 'wss:';
    const payload = JSON.stringify({ transport: 'zcode-relay', url: original.href, relayURL: relay.href });
    document.getElementById('json').value = payload;
    document.getElementById('payload').style.display = 'block';
    status.textContent = `专属中转：${original.host}。仅连接此服务上重新生成的桌面配对信息。`;
    document.getElementById('copy').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(payload); status.textContent = '已复制。请粘贴到原生 App 的专属 Relay 入口。'; }
      catch { status.textContent = '未能复制，请长按选择连接信息后复制。'; }
    });
  } catch { status.textContent = '配对信息无效，或此页面与配对服务不一致。请在原电脑重新生成此服务的二维码。'; }
})();
