(() => {
  "use strict";

  const MAX_UPLOAD_BYTES = 256 * 1024 * 1024;
  const MAX_TEXT_BODY_BYTES = 64 * 1024;
  const AUTO_REFRESH_INTERVAL = 10000;

  const elements = {
    alert: document.getElementById("session-alert"),
    alertText: document.getElementById("session-alert-text"),
    connectionStatus: document.getElementById("connection-status"),
    connectionLabel: document.getElementById("connection-label"),
    refreshButton: document.getElementById("refresh-button"),
    downloadAllButton: document.getElementById("download-all-button"),
    itemCount: document.getElementById("item-count"),
    loadingList: document.getElementById("loading-list"),
    itemList: document.getElementById("item-list"),
    emptyState: document.getElementById("empty-state"),
    emptyTitle: document.getElementById("empty-title"),
    emptyDescription: document.getElementById("empty-description"),
    lastUpdated: document.getElementById("last-updated"),
    fileInput: document.getElementById("file-input"),
    dropZone: document.getElementById("drop-zone"),
    uploadQueue: document.getElementById("upload-queue"),
    queueList: document.getElementById("queue-list"),
    queueSummary: document.getElementById("queue-summary"),
    textForm: document.getElementById("text-form"),
    textInput: document.getElementById("text-input"),
    textCount: document.getElementById("text-count"),
    textStatus: document.getElementById("text-status"),
    sendTextButton: document.getElementById("send-text-button"),
    sendButtonLabel: document.querySelector(".send-button-label"),
    toast: document.getElementById("toast")
  };

  const token = new URLSearchParams(window.location.search).get("token") || "";
  const state = {
    refreshing: false,
    uploading: false,
    sendingText: false,
    interactionEnabled: Boolean(token),
    linkExpired: false,
    uploadEntries: [],
    downloads: [],
    toastTimer: null,
    lastRefresh: null
  };

  class APIError extends Error {
    constructor(message, status) {
      super(message);
      this.name = "APIError";
      this.status = status;
    }
  }

  function createElement(tagName, className, text) {
    const node = document.createElement(tagName);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function apiURL(path) {
    const url = new URL(path, window.location.origin);
    url.searchParams.set("token", token);
    return url.toString();
  }

  async function requestJSON(path, options) {
    let response;
    try {
      response = await fetch(apiURL(path), {
        cache: "no-store",
        ...options
      });
    } catch (_error) {
      throw new APIError("无法连接这台电脑，请确认仍在同一局域网。", 0);
    }

    let payload = null;
    try {
      payload = await response.json();
    } catch (_error) {
      // A malformed server response is surfaced below with a useful message.
    }

    if (!response.ok) {
      const serverMessage = payload && typeof payload.error === "string" ? payload.error : "请求没有完成，请稍后再试。";
      throw new APIError(serverMessage, response.status);
    }

    if (!payload || typeof payload !== "object") {
      throw new APIError("这台电脑返回了无法识别的数据。", response.status);
    }
    return payload;
  }

  function showAlert(message, kind = "error") {
    elements.alert.className = `status-banner ${kind}`;
    elements.alertText.textContent = message;
    elements.alert.hidden = false;
  }

  function clearAlert() {
    elements.alert.hidden = true;
    elements.alertText.textContent = "";
    elements.alert.className = "status-banner";
  }

  function setConnectionState(connected, label) {
    elements.connectionStatus.classList.toggle("is-offline", !connected);
    elements.connectionLabel.textContent = label || (connected ? "已连接" : "连接中断");
  }

  function showToast(message) {
    window.clearTimeout(state.toastTimer);
    elements.toast.textContent = message;
    elements.toast.hidden = false;
    state.toastTimer = window.setTimeout(() => {
      elements.toast.hidden = true;
      elements.toast.textContent = "";
    }, 2800);
  }

  function setInteractionEnabled(enabled) {
    state.interactionEnabled = enabled;
    elements.fileInput.disabled = !enabled;
    elements.dropZone.classList.toggle("is-disabled", !enabled);
    elements.dropZone.setAttribute("aria-disabled", String(!enabled));
    elements.textInput.disabled = !enabled;
    updateTextButton();
  }

  function formatBytes(value) {
    if (value === null || value === undefined || value === "") return "";
    const bytes = Number(value);
    if (!Number.isFinite(bytes) || bytes < 0) return "";
    if (bytes < 1024) return `${Math.round(bytes)} B`;
    const units = ["KB", "MB", "GB", "TB"];
    let amount = bytes / 1024;
    let unitIndex = 0;
    while (amount >= 1024 && unitIndex < units.length - 1) {
      amount /= 1024;
      unitIndex += 1;
    }
    const digits = amount >= 100 ? 0 : amount >= 10 ? 1 : 2;
    return `${amount.toFixed(digits)} ${units[unitIndex]}`;
  }

  function formatDate(value) {
    if (typeof value !== "string") return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";

    const now = Date.now();
    const difference = now - date.getTime();
    if (difference >= 0 && difference < 60000) return "刚刚";
    if (difference >= 60000 && difference < 3600000) return `${Math.floor(difference / 60000)} 分钟前`;

    const sameDay = new Date().toDateString() === date.toDateString();
    return new Intl.DateTimeFormat("zh-CN", {
      ...(sameDay ? {} : { month: "numeric", day: "numeric" }),
      hour: "2-digit",
      minute: "2-digit"
    }).format(date);
  }

  function kindLabel(kind) {
    if (kind === "image") return "图片";
    if (kind === "text") return "文字";
    return "文件";
  }

  function sourceLabel(source) {
    if (source === "teacher") return "老师分享";
    if (source === "browser") return "同学上传";
    return "";
  }

  function safeDownloadURL(value) {
    if (typeof value !== "string" || value.length === 0) return null;
    try {
      const url = new URL(value, window.location.origin);
      if (url.origin !== window.location.origin || !url.pathname.startsWith("/download/")) return null;
      url.searchParams.set("token", token);
      return url.toString();
    } catch (_error) {
      return null;
    }
  }

  async function copyText(value) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(value);
      return;
    }
    const temporary = document.createElement("textarea");
    temporary.value = value;
    temporary.setAttribute("readonly", "");
    temporary.style.position = "fixed";
    temporary.style.opacity = "0";
    document.body.appendChild(temporary);
    temporary.select();
    const copied = document.execCommand("copy");
    temporary.remove();
    if (!copied) throw new Error("copy failed");
  }

  function createItemVisual(item, downloadURL) {
    const visual = createElement("div", `item-visual ${item.kind === "text" ? "text" : item.kind === "image" ? "image" : "file"}`);
    visual.setAttribute("aria-hidden", "true");
    visual.textContent = item.kind === "text" ? "Aa" : item.kind === "image" ? "IMG" : "FILE";

    if (item.kind === "image" && downloadURL) {
      const image = document.createElement("img");
      image.className = "item-thumbnail";
      image.alt = "";
      image.loading = "lazy";
      image.decoding = "async";
      image.src = downloadURL;
      image.addEventListener("error", () => image.remove(), { once: true });
      visual.appendChild(image);
    }
    return visual;
  }

  function createSharedItem(rawItem) {
    const item = rawItem && typeof rawItem === "object" ? rawItem : {};
    const kind = ["file", "image", "text"].includes(item.kind) ? item.kind : "file";
    const name = typeof item.name === "string" && item.name.trim() ? item.name : "未命名内容";
    const detail = typeof item.detail === "string" ? item.detail : "";
    const downloadURL = safeDownloadURL(item.downloadURL);
    const normalized = { ...item, kind };

    const row = createElement("article", "shared-item");
    row.setAttribute("role", "listitem");
    row.appendChild(createItemVisual(normalized, downloadURL));

    const copy = createElement("div", "item-copy");
    copy.appendChild(createElement("p", "item-name", kind === "text" && detail ? detail : name));

    const meta = createElement("div", "item-meta");
    const sourceText = sourceLabel(item.source);
    if (sourceText) {
      const sourceClass = item.source === "teacher" ? "teacher" : "browser";
      meta.appendChild(createElement("span", `source-badge ${sourceClass}`, sourceText));
    }
    meta.appendChild(createElement("span", "", kindLabel(kind)));
    const sizeText = formatBytes(item.size);
    if (sizeText) meta.appendChild(createElement("span", "", sizeText));
    const dateText = formatDate(item.createdAt);
    if (dateText) meta.appendChild(createElement("span", "", dateText));
    copy.appendChild(meta);
    row.appendChild(copy);

    const actions = createElement("div", "item-actions");
    if (kind === "text") {
      const copyButton = createElement("button", "item-action secondary", "复制文字");
      copyButton.type = "button";
      copyButton.addEventListener("click", async () => {
        try {
          await copyText(detail || name);
          copyButton.textContent = "已复制";
          showToast("文字已复制到剪贴板");
          window.setTimeout(() => { copyButton.textContent = "复制文字"; }, 1600);
        } catch (_error) {
          showToast("复制失败，请长按文字手动复制");
        }
      });
      actions.appendChild(copyButton);
    } else if (downloadURL) {
      const downloadLink = createElement("a", "item-action", "下载");
      downloadLink.href = downloadURL;
      downloadLink.download = name;
      downloadLink.rel = "noopener";
      downloadLink.addEventListener("click", () => showToast(`开始下载：${name}`));
      actions.appendChild(downloadLink);
    } else {
      const unavailable = createElement("span", "item-action disabled", "暂不可用");
      unavailable.setAttribute("aria-disabled", "true");
      actions.appendChild(unavailable);
    }
    row.appendChild(actions);
    return row;
  }

  function renderItems(items) {
    const safeItems = Array.isArray(items) ? items : [];
    elements.itemList.replaceChildren();
    state.downloads = safeItems.reduce((downloads, rawItem) => {
      if (!rawItem || typeof rawItem !== "object" || rawItem.kind === "text") return downloads;
      const url = safeDownloadURL(rawItem.downloadURL);
      if (url) {
        downloads.push({
          url,
          name: typeof rawItem.name === "string" && rawItem.name.trim() ? rawItem.name : "未命名文件"
        });
      }
      return downloads;
    }, []);
    elements.downloadAllButton.disabled = state.downloads.length === 0;
    elements.itemCount.textContent = String(safeItems.length);
    elements.itemCount.setAttribute("aria-label", `${safeItems.length} 项共享内容`);

    safeItems.forEach((item) => elements.itemList.appendChild(createSharedItem(item)));
    elements.emptyState.hidden = safeItems.length !== 0;
  }

  function renderLoadFailure(message) {
    elements.itemList.replaceChildren();
    state.downloads = [];
    elements.downloadAllButton.disabled = true;
    elements.itemCount.textContent = "—";
    elements.emptyTitle.textContent = "暂时无法读取内容";
    elements.emptyDescription.textContent = message;
    elements.emptyState.hidden = false;
  }

  function resetEmptyCopy() {
    elements.emptyTitle.textContent = "还没有共享内容";
    elements.emptyDescription.textContent = "老师或同学上传文件、发送文字后，会立即出现在这里。";
  }

  function expireLink() {
    state.linkExpired = true;
    renderLoadFailure("共享访问码已经更换，请向分享者获取新链接。");
    setConnectionState(false, "链接失效");
    showAlert("共享链接已失效，请向分享者获取新链接。");
    state.lastRefresh = null;
    elements.lastUpdated.textContent = "等待新的共享链接";
    setInteractionEnabled(false);
    elements.refreshButton.disabled = true;
  }

  async function refreshItems({ initial = false, quiet = false } = {}) {
    if (state.refreshing || !token || state.linkExpired) return;
    state.refreshing = true;
    elements.refreshButton.disabled = true;
    elements.refreshButton.classList.add("is-loading");
    elements.refreshButton.setAttribute("aria-busy", "true");
    if (initial) {
      elements.loadingList.hidden = false;
      elements.emptyState.hidden = true;
    }

    try {
      const payload = await requestJSON("/api/items");
      // Another request may have learned that this URL expired while this
      // refresh was still in flight. Never let a late success revive stale UI.
      if (state.linkExpired) return;
      resetEmptyCopy();
      renderItems(payload.items);
      state.lastRefresh = new Date();
      elements.lastUpdated.textContent = `刚刚更新 · 页面每 10 秒自动刷新`;
      setConnectionState(true, "已连接");
      clearAlert();
      if (!quiet && !initial) showToast("共享内容已刷新");
    } catch (error) {
      const message = error instanceof Error ? error.message : "无法读取共享内容。";
      const linkExpired = error instanceof APIError && error.status === 403;
      if (initial || linkExpired) {
        renderLoadFailure(linkExpired ? "共享访问码已经更换，请向分享者获取新链接。" : message);
      }
      if (linkExpired) {
        expireLink();
      } else {
        setConnectionState(false, "连接中断");
        showAlert(message);
      }
    } finally {
      elements.loadingList.hidden = true;
      elements.refreshButton.disabled = !state.interactionEnabled;
      elements.refreshButton.classList.remove("is-loading");
      elements.refreshButton.removeAttribute("aria-busy");
      state.refreshing = false;
    }
  }

  async function refreshPublicListAfterPublish() {
    while (state.refreshing && state.interactionEnabled) {
      await new Promise((resolve) => window.setTimeout(resolve, 50));
    }
    if (state.interactionEnabled) await refreshItems({ quiet: true });
  }

  function statusLabel(status) {
    if (status === "waiting") return "等待中";
    if (status === "uploading") return "正在发送…";
    if (status === "success") return "已送达";
    return "发送失败";
  }

  function renderUploadQueue() {
    const entries = state.uploadEntries;
    elements.uploadQueue.hidden = entries.length === 0;
    elements.queueList.replaceChildren();

    const finished = entries.filter((entry) => entry.status === "success" || entry.status === "error").length;
    elements.queueSummary.textContent = entries.length ? `${finished}/${entries.length}` : "";

    entries.forEach((entry) => {
      const row = createElement("div", `queue-item ${entry.status}`);
      row.appendChild(createElement("span", "queue-file-name", entry.file.name || "未命名文件"));
      row.appendChild(createElement("span", "queue-status", statusLabel(entry.status)));
      if (entry.status === "error" && entry.message) {
        row.appendChild(createElement("p", "queue-message", entry.message));
      }
      elements.queueList.appendChild(row);
    });
  }

  async function uploadSingleFile(entry) {
    entry.status = "uploading";
    renderUploadQueue();

    const formData = new FormData();
    formData.append("file", entry.file, entry.file.name);
    try {
      await requestJSON("/api/upload", {
        method: "POST",
        body: formData
      });
      entry.status = "success";
      entry.message = "文件已上传到课堂共享区";
      return true;
    } catch (error) {
      entry.status = "error";
      entry.message = error instanceof Error ? error.message : "发送失败";
      if (error instanceof APIError && error.status === 403) {
        expireLink();
      }
      return false;
    } finally {
      renderUploadQueue();
    }
  }

  async function handleFiles(fileList) {
    const files = Array.from(fileList || []);
    if (!files.length) return;
    if (!token || !state.interactionEnabled) {
      showAlert("共享链接缺少访问凭证，请向分享者获取完整链接。");
      return;
    }
    if (state.uploading) {
      showToast("请等待当前文件传输完成");
      return;
    }

    state.uploadEntries = files.map((file) => ({
      file,
      status: file.size > MAX_UPLOAD_BYTES ? "error" : "waiting",
      message: file.size > MAX_UPLOAD_BYTES ? "文件超过 256 MB 限制" : ""
    }));
    renderUploadQueue();

    state.uploading = true;
    elements.fileInput.disabled = true;
    elements.dropZone.classList.add("is-disabled");
    elements.dropZone.setAttribute("aria-disabled", "true");

    let succeeded = 0;
    for (const entry of state.uploadEntries) {
      if (entry.status === "error") continue;
      if (!state.interactionEnabled) {
        entry.status = "error";
        entry.message = "共享链接已失效";
        renderUploadQueue();
        continue;
      }
      if (await uploadSingleFile(entry)) {
        succeeded += 1;
        await refreshPublicListAfterPublish();
      }
    }

    state.uploading = false;
    elements.fileInput.disabled = !state.interactionEnabled;
    elements.fileInput.value = "";
    elements.dropZone.classList.toggle("is-disabled", !state.interactionEnabled);
    elements.dropZone.setAttribute("aria-disabled", String(!state.interactionEnabled));

    const failed = state.uploadEntries.length - succeeded;
    if (succeeded && !failed) {
      showToast(`${succeeded} 个文件已上传到课堂共享区`);
    } else if (succeeded) {
      showToast(`${succeeded} 个已上传，${failed} 个上传失败`);
    } else {
      showToast("文件没有上传成功，请查看传输记录");
    }
  }

  function downloadAllItems() {
    if (!state.downloads.length) return;
    state.downloads.forEach((item) => {
      const link = document.createElement("a");
      link.href = item.url;
      link.download = item.name;
      link.rel = "noopener";
      document.body.appendChild(link);
      link.click();
      link.remove();
    });
    showToast(state.downloads.length === 1 ? "已开始下载" : `正在下载 ${state.downloads.length} 个文件，浏览器可能会询问是否允许`);
  }

  function textBodySize() {
    return new Blob([JSON.stringify({ text: elements.textInput.value })]).size;
  }

  function updateTextButton() {
    const trimmed = elements.textInput.value.trim();
    const bodySize = textBodySize();
    const tooLarge = bodySize > MAX_TEXT_BODY_BYTES;
    elements.textCount.textContent = `${formatBytes(new Blob([elements.textInput.value]).size)} / 64 KB`;
    elements.textCount.classList.toggle("warning", tooLarge);
    elements.sendTextButton.disabled = !token || elements.textInput.disabled || state.sendingText || !trimmed || tooLarge;
  }

  function setTextStatus(message, kind = "") {
    elements.textStatus.textContent = message;
    elements.textStatus.className = `inline-status ${kind}`.trim();
  }

  async function sendText() {
    const text = elements.textInput.value.trim();
    if (!text || state.sendingText) return;
    const body = JSON.stringify({ text });
    if (new Blob([body]).size > MAX_TEXT_BODY_BYTES) {
      setTextStatus("文字内容超过 64 KB，请缩短后再发送。", "error");
      updateTextButton();
      return;
    }

    state.sendingText = true;
    elements.sendTextButton.classList.add("is-loading");
    elements.sendButtonLabel.textContent = "正在发送";
    elements.textInput.disabled = true;
    updateTextButton();
    setTextStatus("正在发布到课堂共享区…");

    try {
      await requestJSON("/api/text", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body
      });
      elements.textInput.value = "";
      setTextStatus("已发布，所有打开链接的人现在都能看到。", "success");
      showToast("文字已发布到课堂共享区");
      await refreshPublicListAfterPublish();
    } catch (error) {
      if (error instanceof APIError && error.status === 403) {
        expireLink();
      }
      setTextStatus(error instanceof Error ? error.message : "文字发送失败，请重试。", "error");
    } finally {
      state.sendingText = false;
      elements.sendTextButton.classList.remove("is-loading");
      elements.sendButtonLabel.textContent = "发送";
      elements.textInput.disabled = !state.interactionEnabled;
      updateTextButton();
      if (state.interactionEnabled) elements.textInput.focus();
    }
  }

  function bindEvents() {
    elements.refreshButton.addEventListener("click", () => refreshItems());
    elements.downloadAllButton.addEventListener("click", downloadAllItems);
    elements.fileInput.addEventListener("change", () => handleFiles(elements.fileInput.files));
    elements.dropZone.addEventListener("click", () => {
      if (!state.uploading && state.interactionEnabled) elements.fileInput.click();
    });
    elements.dropZone.addEventListener("keydown", (event) => {
      if ((event.key === "Enter" || event.key === " ") && !state.uploading && state.interactionEnabled) {
        event.preventDefault();
        elements.fileInput.click();
      }
    });

    let dragDepth = 0;
    elements.dropZone.addEventListener("dragenter", (event) => {
      event.preventDefault();
      dragDepth += 1;
      if (!state.uploading) elements.dropZone.classList.add("is-dragging");
    });
    elements.dropZone.addEventListener("dragover", (event) => {
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = state.uploading ? "none" : "copy";
    });
    elements.dropZone.addEventListener("dragleave", (event) => {
      event.preventDefault();
      dragDepth = Math.max(0, dragDepth - 1);
      if (dragDepth === 0) elements.dropZone.classList.remove("is-dragging");
    });
    elements.dropZone.addEventListener("drop", (event) => {
      event.preventDefault();
      dragDepth = 0;
      elements.dropZone.classList.remove("is-dragging");
      if (!state.uploading && state.interactionEnabled && event.dataTransfer) handleFiles(event.dataTransfer.files);
    });
    window.addEventListener("dragover", (event) => event.preventDefault());
    window.addEventListener("drop", (event) => event.preventDefault());

    elements.textInput.addEventListener("input", () => {
      updateTextButton();
      if (elements.textStatus.classList.contains("error")) setTextStatus("");
    });
    elements.textInput.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        if (!elements.sendTextButton.disabled) sendText();
      }
    });
    elements.textForm.addEventListener("submit", (event) => {
      event.preventDefault();
      sendText();
    });
  }

  function initialize() {
    bindEvents();
    updateTextButton();

    if (!token) {
      setConnectionState(false, "链接无效");
      elements.loadingList.hidden = true;
      renderLoadFailure("请向分享者获取包含访问凭证的完整链接。");
      showAlert("共享链接不完整，缺少访问凭证。请重新打开或复制完整链接。 ");
      setInteractionEnabled(false);
      elements.refreshButton.disabled = true;
      return;
    }

    setInteractionEnabled(true);
    refreshItems({ initial: true, quiet: true });
    window.setInterval(() => {
      if (document.visibilityState === "visible") refreshItems({ quiet: true });
    }, AUTO_REFRESH_INTERVAL);
  }

  initialize();
})();
