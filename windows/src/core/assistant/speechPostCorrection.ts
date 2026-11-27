import type { HomeScene, SmartDevice } from "../models.js";
/** Lightweight Windows Web Speech post-correction anchored strictly to current home hotwords. */
const HOMOPHONE_GROUPS = [
  "书舒树输梳", "房防访仿", "客克可刻", "厅听亭停", "卧握沃", "室视式事试市", "厨出除初", "阳扬洋羊杨",
  "台太抬泰态", "卫为味位未", "生声升胜", "间见建件健", "餐参残", "玄悬选旋", "走奏", "廊郎朗浪",
  "次此刺赐", "主住煮柱", "吸洗西息希稀悉", "顶定订丁盯", "灯登等邓", "带代袋戴待", "落洛络", "底地第弟",
  "床创窗", "帘连联莲练", "头投偷", "补不步布部", "光广逛", "空孔控恐", "调条跳挑", "风封峰丰蜂",
  "扇善山衫杉", "循寻巡旬", "环还换欢", "加家佳嘉夹", "湿师施失诗时", "净静进境经劲", "化话画花华",
  "器气汽弃", "扫少骚哨", "机鸡积基极", "插查叉茶察", "座做作坐左", "暖软", "电店垫殿", "浴玉育遇预",
  "幕木目牧", "屏平评瓶凭", "挂瓜刮", "氛分份纷", "围为维微",
];
const CHAR_KEY = new Map<string, string>(HOMOPHONE_GROUPS.flatMap((g) => { const a = Array.from(g); return a.map((c) => [c, a[0]!] as const); }));
const PROTECTED = new Set(["打开", "关闭", "开启", "关掉", "调亮", "调暗", "调高", "调低", "设成", "设为", "设置", "撤销", "取消", "全部", "全屋", "所有"]);
const isCjk = (ch: string): boolean => /[\u3400-\u9fff]/.test(ch);
const phonetic = (s: string): string => Array.from(s).map((c) => CHAR_KEY.get(c) ?? c).join("");
export interface SpeechHotwordContext {
  readonly devices: readonly SmartDevice[]; readonly scenes?: readonly HomeScene[];
  readonly rooms?: readonly { readonly name: string }[]; readonly aliases?: Readonly<Record<string, string>>;
}
export function collectSpeechHotwords(context: SpeechHotwordContext): string[] {
  const seen = new Set<string>(), terms: string[] = [];
  const push = (raw: string | undefined): void => {
    const t = raw?.trim();
    if (!t || terms.length >= 100 || t.length < 2 || seen.has(t)) return;
    seen.add(t); terms.push(t);
  };
  for (const d of context.devices) { push(context.aliases?.[d.id]); push(d.name); push(d.roomName); }
  for (const r of context.rooms ?? []) push(r.name);
  for (const s of context.scenes ?? []) push(s.name);
  return terms.sort((a, b) => Array.from(b).length - Array.from(a).length);
}
export function correctSpeechTranscript(rawTranscript: string, context: SpeechHotwordContext): string {
  let text = rawTranscript.trim().replace(/([\u3400-\u9fff])\s+(?=[\u3400-\u9fff])/g, "$1").replace(/\s{2,}/g, " ");
  if (!text) return "";
  const hotwords = collectSpeechHotwords(context);
  if (hotwords.length === 0) return text;
  for (const term of hotwords) {
    if (!/[A-Za-z]/.test(term) || !/\s/.test(term)) continue;
    const squashed = term.replace(/\s+/g, "").toLowerCase();
    if (squashed.length >= 4) text = text.replace(new RegExp(`\\b${squashed.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "gi"), term);
  }
  const exactSet = new Set(hotwords), cjk = hotwords.filter((t) => Array.from(t).length >= 2 && Array.from(t).every(isCjk)).map((term) => ({ term, chars: Array.from(term), sig: phonetic(term) }));
  if (cjk.length === 0) return text;
  const chars = Array.from(text), locked = new Array<boolean>(chars.length).fill(false);
  for (const e of cjk) for (let i = 0; i <= chars.length - e.chars.length; i += 1) if (chars.slice(i, i + e.chars.length).join("") === e.term) locked.fill(true, i, i + e.chars.length);
  for (const e of cjk) {
    const len = e.chars.length;
    for (let i = 0; i <= chars.length - len; i += 1) {
      if (locked.slice(i, i + len).some(Boolean) || !chars.slice(i, i + len).every(isCjk)) continue;
      const slice = chars.slice(i, i + len).join("");
      if (slice === e.term || exactSet.has(slice) || PROTECTED.has(slice) || phonetic(slice) !== e.sig) continue;
      for (let k = 0; k < len; k += 1) { chars[i + k] = e.chars[k]!; locked[i + k] = true; }
    }
  }
  return chars.join("");
}
