import { MiCloudCrypto } from "../miCloudCrypto.js";
import {
  asIdString,
  MiCloudError,
  parseJsonObject,
  type HttpTransport,
  type MiSession,
  type QRLoginTicket,
} from "./session.js";

export class MiAccountLogin {
  private readonly transport: HttpTransport;
  private readonly region: string;

  constructor(transport: HttpTransport, region = "cn") {
    this.transport = transport;
    this.region = region;
  }

  async start(nowMs = Date.now()): Promise<QRLoginTicket> {
    const query = MiCloudCrypto.formURLEncode([
      ["_qrsize", "480"],
      ["qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"],
      ["callback", "https://sts.api.io.mi.com/sts"],
      ["_hasLogo", "false"],
      ["sid", "xiaomiio"],
      ["serviceParam", ""],
      ["_locale", "zh_CN"],
      ["_dc", String(nowMs)],
    ]);
    const resp = await this.transport({
      url: `https://account.xiaomi.com/longPolling/loginUrl?${query}`,
      method: "GET",
    });
    if (resp.status !== 200) {
      throw new MiCloudError("http", `小米账号服务返回 HTTP ${resp.status}`, resp.status);
    }
    return MiAccountLogin.parseTicket(resp.body);
  }

  static parseTicket(body: string): QRLoginTicket {
    const json = parseJsonObject(body);
    if (!json) throw new MiCloudError("badResponse", "小米账号服务响应非 JSON");
    const qr = typeof json["qr"] === "string" ? json["qr"] : null;
    const loginUrl = typeof json["loginUrl"] === "string" ? json["loginUrl"] : null;
    const lp = typeof json["lp"] === "string" ? json["lp"] : null;
    if (!qr || !loginUrl || !lp) {
      const code = asIdString(json["code"]) ?? "?";
      throw new MiCloudError("badResponse", `缺少二维码字段 (code ${code})`);
    }
    const timeoutRaw = json["timeout"];
    const timeout =
      typeof timeoutRaw === "number"
        ? timeoutRaw
        : typeof timeoutRaw === "string"
          ? Number(timeoutRaw) || 300
          : 300;
    return { qrImageURL: qr, loginURL: loginUrl, longPollURL: lp, timeout };
  }

  static parseScanResult(body: string): {
    userId: string;
    cUserId: string;
    ssecurity: string;
    passToken: string;
    location: string;
  } {
    const json = parseJsonObject(body);
    if (!json) throw new MiCloudError("badResponse", "扫码结果非 JSON");
    const userId = asIdString(json["userId"]);
    const ssecurity = typeof json["ssecurity"] === "string" ? json["ssecurity"] : null;
    const location = typeof json["location"] === "string" ? json["location"] : null;
    if (!userId || !ssecurity || !location) {
      const code = asIdString(json["code"]) ?? "?";
      throw new MiCloudError("badResponse", `扫码结果缺少字段 (code ${code})`);
    }
    return {
      userId,
      cUserId: asIdString(json["cUserId"]) ?? "",
      ssecurity,
      passToken: typeof json["passToken"] === "string" ? json["passToken"] : "",
      location,
    };
  }

  async waitForScan(ticket: QRLoginTicket, signal?: AbortSignal): Promise<MiSession> {
    const deadline = Date.now() + ticket.timeout * 1000;
    let scanned: ReturnType<typeof MiAccountLogin.parseScanResult> | null = null;
    while (!scanned) {
      if (signal?.aborted) throw new Error("Cancelled");
      if (Date.now() >= deadline) {
        throw new MiCloudError("badResponse", "二维码已过期，请重新获取");
      }
      try {
        const resp = await this.transport({
          url: ticket.longPollURL,
          method: "GET",
          timeoutMs: 15_000,
        });
        if (resp.status === 200 && resp.body.trim().length > 0) {
          scanned = MiAccountLogin.parseScanResult(resp.body);
        } else {
          await new Promise((r) => setTimeout(r, 800));
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase();
        if (msg.includes("timeout") || msg.includes("timed out")) {
          continue;
        }
        throw err;
      }
    }

    const cookie = await this.fetchServiceToken(scanned.location);
    return {
      userId: scanned.userId,
      cUserId: scanned.cUserId,
      ssecurity: scanned.ssecurity,
      serviceToken: cookie.token,
      passToken: scanned.passToken,
      region: this.region,
      ...(cookie.expiresAt !== undefined ? { expiresAt: cookie.expiresAt } : {}),
    };
  }

  /**
   * Extracts `serviceToken` and its declared expiry from `Set-Cookie` headers (`MiAccountLogin.swift`).
   * Per RFC 6265 §4.1.2.2, `Max-Age` (seconds) takes precedence over `Expires`.
   * Also supports `native_http`'s `; `-flattened header representation (`userId=1; Path=/; serviceToken=tok; Path=/`).
   */
  static parseServiceTokenCookie(
    headers: Readonly<Record<string, string>>,
    nowMs = Date.now(),
  ): { token: string; expiresAt?: number } | null {
    const rawHeaders: string[] = [];
    for (const [key, value] of Object.entries(headers)) {
      if (key.toLowerCase() !== "set-cookie" || !value) continue;
      const separated = value.replace(/,\s*(?=[^;,=\s]+=)/g, "\n");
      rawHeaders.push(...separated.split("\n"));
    }
    for (const header of rawHeaders) {
      const parts = header
        .split(";")
        .map((part) => part.trim())
        .filter((part) => part.length > 0);
      for (let i = 0; i < parts.length; i += 1) {
        const part = parts[i]!;
        const eq = part.indexOf("=");
        if (eq < 0) continue;
        const cookieName = part.slice(0, eq).trim();
        const cookieValue = part.slice(eq + 1).trim();
        if (cookieName !== "serviceToken" || cookieValue.length === 0) continue;

        let maxAgeSeconds: number | undefined;
        let expiresMs: number | undefined;
        for (let j = i + 1; j < parts.length; j += 1) {
          const attr = parts[j]!;
          const attrEq = attr.indexOf("=");
          if (attrEq < 0) continue;
          const attrName = attr.slice(0, attrEq).trim().toLowerCase();
          if (!COOKIE_ATTR_NAMES.has(attrName)) {
            // Next cookie in a `; `-flattened `Set-Cookie` header (`native_http`).
            break;
          }
          const attrVal = attr.slice(attrEq + 1).trim();
          if (attrName === "max-age" && /^[-+]?\d+$/.test(attrVal)) {
            const parsed = Number.parseInt(attrVal, 10);
            if (Number.isFinite(parsed)) maxAgeSeconds = parsed;
          } else if (attrName === "expires") {
            const parsedDate = parseHttpCookieDate(attrVal);
            if (parsedDate !== null) expiresMs = parsedDate;
          }
        }
        if (maxAgeSeconds !== undefined) {
          return {
            token: cookieValue,
            expiresAt: maxAgeSeconds <= 0 ? nowMs : nowMs + maxAgeSeconds * 1000,
          };
        }
        return expiresMs !== undefined ? { token: cookieValue, expiresAt: expiresMs } : { token: cookieValue };
      }
    }
    return null;
  }

  private async fetchServiceToken(initialLocation: string): Promise<{ token: string; expiresAt?: number }> {
    let url = initialLocation;
    for (let i = 0; i < 5; i++) {
      const resp = await this.transport({
        url,
        method: "GET",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        followRedirects: false,
      });
      const parsedCookie = MiAccountLogin.parseServiceTokenCookie(resp.headers);
      if (parsedCookie) {
        return parsedCookie;
      }
      const nextLoc = resp.headers["location"] ?? resp.headers["Location"];
      if (resp.status >= 300 && resp.status < 400 && nextLoc) {
        url = new URL(nextLoc, url).toString();
        continue;
      }
      break;
    }
    throw new MiCloudError("badResponse", "登录成功但未拿到 serviceToken，请重试");
  }
}

const COOKIE_ATTR_NAMES = new Set([
  "expires",
  "max-age",
  "domain",
  "path",
  "secure",
  "httponly",
  "samesite",
  "priority",
  "partitioned",
  "version",
  "comment",
]);

function parseHttpCookieDate(raw: string): number | null {
  const normalized = raw.trim().replace(/^([A-Za-z]+,\s*\d{1,2})-([A-Za-z]{3})-(\d{2,4})\b/, (_m, prefix: string, mon: string, yr: string) => {
    const fullYear = yr.length === 2 ? (Number(yr) >= 70 ? `19${yr}` : `20${yr}`) : yr;
    return `${prefix} ${mon} ${fullYear}`;
  });
  const ms = Date.parse(normalized);
  return Number.isFinite(ms) ? ms : null;
}
