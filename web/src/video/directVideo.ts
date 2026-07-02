// Finds and controls the active HTML5 <video> on the page — including videos nested
// in (open or closed) shadow DOM — and exposes the playback primitives the annotator
// needs: the web analogue of VLC's now_seconds() / seek_by() / play_pause().
//
// Key simplification vs VLC: HTML5 video.currentTime is already in SECONDS, so there
// is no microsecond conversion. This handler covers same-origin/top-frame videos
// (including youtube.com/watch, whose player is in the main page). Cross-origin
// EMBEDDED players (e.g. a youtube.com/embed iframe on a third-party site) are a
// separate, later handler — they live in a frame this top-frame script can't reach.

// chrome.dom.openOrClosedShadowRoot lets a content script pierce CLOSED shadow roots
// (Chrome/Firefox); fall back to the public .shadowRoot otherwise.
function openOrClosed(el: Element): ShadowRoot | null {
  const anyChrome = (globalThis as unknown as { chrome?: any }).chrome;
  try {
    if (anyChrome?.dom?.openOrClosedShadowRoot) {
      return anyChrome.dom.openOrClosedShadowRoot(el) ?? null;
    }
  } catch {
    /* ignore */
  }
  return (el as unknown as { shadowRoot?: ShadowRoot | null }).shadowRoot ?? null;
}

function collectVideos(root: ParentNode, acc: HTMLVideoElement[], depth: number): void {
  if (depth > 8) return; // bound the shadow-DOM walk
  root.querySelectorAll("video").forEach((v) => acc.push(v as HTMLVideoElement));
  root.querySelectorAll("*").forEach((el) => {
    const sr = openOrClosed(el as Element);
    if (sr) collectVideos(sr, acc, depth + 1);
  });
}

export class DirectVideoHandler {
  private current: HTMLVideoElement | null = null;

  findActive(): HTMLVideoElement | null {
    const vids: HTMLVideoElement[] = [];
    collectVideos(document, vids, 0);
    if (vids.length === 0) {
      this.current = null;
      return null;
    }
    // Prefer a currently-playing video; tie-break by largest rendered area.
    const score = (v: HTMLVideoElement) => {
      const r = v.getBoundingClientRect();
      const area = Math.max(0, r.width) * Math.max(0, r.height);
      return (v.paused ? 0 : 1e12) + area;
    };
    vids.sort((a, b) => score(b) - score(a));
    this.current = vids[0];
    return this.current;
  }

  private active(): HTMLVideoElement | null {
    if (this.current && this.current.isConnected) return this.current;
    return this.findActive();
  }

  hasVideo(): boolean {
    return this.active() != null;
  }

  now(): number | null {
    const v = this.active();
    return v ? v.currentTime : null;
  }

  /**
   * Read currentTime from the CACHED video element only — no DOM scan.
   * Use this for high-frequency polling (e.g. the panel clock) so a
   * hidden panel on a video-less page doesn't trigger a full shadow-piercing
   * querySelectorAll("*") walk every 333ms.
   */
  peekNow(): number | null {
    const v = this.current;
    return v && v.isConnected ? v.currentTime : null;
  }

  duration(): number | null {
    const v = this.active();
    return v && Number.isFinite(v.duration) ? v.duration : null;
  }

  isPaused(): boolean | null {
    const v = this.active();
    return v ? v.paused : null;
  }

  seekBy(delta: number): boolean {
    const v = this.active();
    if (!v) return false;
    let t = v.currentTime + delta;
    if (t < 0) t = 0;
    v.currentTime = t;
    return true;
  }

  // Single toggle gated on actual paused state (mirrors the Lua play_pause()).
  playPause(): "playing" | "paused" | null {
    const v = this.active();
    if (!v) return null;
    if (v.paused) {
      void v.play().catch(() => {});
      return "playing";
    }
    v.pause();
    return "paused";
  }
}
