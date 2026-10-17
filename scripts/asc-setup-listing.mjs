// App Store Connect API で、App Store の掲載情報を登録する。
// 文章は docs/store-listing.md の各見出しから読む（ここを直せば掲載文も変わる）。
//
// 使い方:
//   ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... node scripts/asc-setup-listing.mjs [--apply] [--screenshots フォルダ]
//   --apply を付けないと、現在の状態を表示するだけで何も変更しない。
//
// API で設定できないもの（App のプライバシー、審査の連絡先）は App Store Connect の画面で行う。
import { createHash, createSign } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";

const BUNDLE_ID = "com.sammy.sakuhincamera";
const apply = process.argv.includes("--apply");
const shotIndex = process.argv.indexOf("--screenshots");
const screenshotDir = shotIndex > 0 ? process.argv[shotIndex + 1] : null;

// --- docs/store-listing.md を読む ---
const markdown = readFileSync(new URL("../docs/store-listing.md", import.meta.url), "utf8");
const sections = {};
for (const part of markdown.split(/^## /m).slice(1)) {
  const [heading, ...body] = part.split("\n");
  sections[heading.replace(/（.*）$/, "").trim()] = body.join("\n").trim();
}
const listing = {
  subtitle: sections["サブタイトル"],
  promotionalText: sections["プロモーションテキスト"],
  description: sections["説明"],
  keywords: sections["キーワード"],
  copyright: sections["著作権"],
  supportUrl: sections["URL"].match(/サポート：(\S+)/)[1],
  privacyPolicyUrl: sections["URL"].match(/プライバシーポリシー：(\S+)/)[1],
  reviewNotes: sections["審査メモ"]
    .split("\n")
    .map((line) => line.replace(/^- /, "・"))
    .join("\n"),
};
for (const [key, value] of Object.entries(listing)) {
  if (!value) throw new Error(`store-listing.md に「${key}」が見つからない`);
}

// --- API ---
const { ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID } = process.env;
if (!ASC_KEY_PATH || !ASC_KEY_ID || !ASC_ISSUER_ID) {
  console.error("ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID を指定してください");
  process.exit(1);
}
const privateKey = readFileSync(ASC_KEY_PATH, "utf8");
function token() {
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const header = b64({ alg: "ES256", kid: ASC_KEY_ID, typ: "JWT" });
  const payload = b64({ iss: ASC_ISSUER_ID, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" });
  const signer = createSign("SHA256");
  signer.update(`${header}.${payload}`);
  return `${header}.${payload}.${signer.sign({ key: privateKey, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}
async function api(method, path, body) {
  const url = path.startsWith("http") ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const detail = (json.errors || []).map((e) => `${e.title}: ${e.detail}`).join(" / ");
    throw new Error(`${method} ${path} → ${res.status} ${detail}`);
  }
  return json;
}
async function getAll(path) {
  let url = path;
  const items = [];
  while (url) {
    const page = await api("GET", url);
    items.push(...page.data);
    url = page.links?.next;
  }
  return items;
}
async function step(label, fn) {
  try {
    console.log(`${label}: ${await fn()}`);
  } catch (error) {
    console.log(`${label}: 失敗 → ${error.message}`);
  }
}

const app = (await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data[0];
const appInfo = (await api("GET", `/v1/apps/${app.id}/appInfos`)).data.find(
  (info) => info.attributes.state !== "READY_FOR_DISTRIBUTION",
);
const version = (await getAll(`/v1/apps/${app.id}/appStoreVersions`)).find(
  (v) => v.attributes.appStoreState === "PREPARE_FOR_SUBMISSION",
);
console.log(`アプリ ${app.attributes.name} / バージョン ${version.attributes.versionString}\n`);

// 1. カテゴリ
await step("カテゴリ", async () => {
  const current = await api("GET", `/v1/appInfos/${appInfo.id}?include=primaryCategory`);
  if (current.data.relationships?.primaryCategory?.data) return "設定済み";
  if (!apply) return "未設定";
  await api("PATCH", `/v1/appInfos/${appInfo.id}`, {
    data: {
      type: "appInfos",
      id: appInfo.id,
      relationships: {
        primaryCategory: { data: { type: "appCategories", id: "PHOTO_AND_VIDEO" } },
        secondaryCategory: { data: { type: "appCategories", id: "LIFESTYLE" } },
      },
    },
  });
  return "写真／ビデオ・ライフスタイルに設定";
});

// 2. サブタイトル・プライバシーポリシー URL（アプリ情報の日本語）
await step("サブタイトル・プライバシーポリシー", async () => {
  const loc = (await getAll(`/v1/appInfos/${appInfo.id}/appInfoLocalizations`)).find((l) => l.attributes.locale === "ja");
  const same = loc.attributes.subtitle === listing.subtitle && loc.attributes.privacyPolicyUrl === listing.privacyPolicyUrl;
  if (same) return "設定済み";
  if (!apply) return "未設定";
  await api("PATCH", `/v1/appInfoLocalizations/${loc.id}`, {
    data: {
      type: "appInfoLocalizations",
      id: loc.id,
      attributes: { subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl },
    },
  });
  return "設定";
});

// 3. 説明文・キーワード・プロモーションテキスト・サポート URL（バージョンの日本語）
let versionLocalization = null;
await step("説明文・キーワード・サポートURL", async () => {
  versionLocalization = (await getAll(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).find(
    (l) => l.attributes.locale === "ja",
  );
  const a = versionLocalization.attributes;
  const same = a.description === listing.description && a.keywords === listing.keywords &&
    a.promotionalText === listing.promotionalText && a.supportUrl === listing.supportUrl;
  if (same) return "設定済み";
  if (!apply) return "未設定または内容が違う";
  await api("PATCH", `/v1/appStoreVersionLocalizations/${versionLocalization.id}`, {
    data: {
      type: "appStoreVersionLocalizations",
      id: versionLocalization.id,
      attributes: {
        description: listing.description,
        keywords: listing.keywords,
        promotionalText: listing.promotionalText,
        supportUrl: listing.supportUrl,
      },
    },
  });
  return "設定";
});

// 4. 著作権
await step("著作権", async () => {
  if (version.attributes.copyright === listing.copyright) return "設定済み";
  if (!apply) return "未設定";
  await api("PATCH", `/v1/appStoreVersions/${version.id}`, {
    data: { type: "appStoreVersions", id: version.id, attributes: { copyright: listing.copyright } },
  });
  return `「${listing.copyright}」に設定`;
});

// 5. 年齢制限（該当なし → 4+）
await step("年齢制限", async () => {
  const declaration = (await api("GET", `/v1/appInfos/${appInfo.id}/ageRatingDeclaration`)).data;
  if (declaration.attributes.violenceRealistic === "NONE") return "設定済み";
  if (!apply) return "未設定";
  const none = [
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "horrorOrFearThemes", "matureOrSuggestiveThemes", "violenceCartoonOrFantasy",
    "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic",
  ];
  const no = [
    "advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat", "parentalControls",
    "ageAssurance", "unrestrictedWebAccess", "userGeneratedContent",
  ];
  const attributes = {};
  for (const key of none) if (key in declaration.attributes) attributes[key] = "NONE";
  for (const key of no) if (key in declaration.attributes) attributes[key] = false;
  await api("PATCH", `/v1/ageRatingDeclarations/${declaration.id}`, {
    data: { type: "ageRatingDeclarations", id: declaration.id, attributes },
  });
  return "すべて「なし」に設定";
});

// 6. 価格（無料）
await step("価格", async () => {
  try {
    const schedule = (await api("GET", `/v1/apps/${app.id}/appPriceSchedule`)).data;
    const prices = await api("GET", `/v1/appPriceSchedules/${schedule.id}/manualPrices`);
    if (prices.data.length > 0) return "設定済み";
  } catch {
    // 未設定
  }
  if (!apply) return "未設定";
  const free = (await api("GET", `/v1/apps/${app.id}/appPricePoints?filter[territory]=USA&limit=200`)).data.find(
    (p) => Number(p.attributes.customerPrice) === 0,
  );
  await api("POST", "/v1/appPriceSchedules", {
    data: {
      type: "appPriceSchedules",
      relationships: {
        app: { data: { type: "apps", id: app.id } },
        baseTerritory: { data: { type: "territories", id: "USA" } },
        manualPrices: { data: [{ type: "appPrices", id: "${free}" }] },
      },
    },
    included: [{
      type: "appPrices",
      id: "${free}",
      attributes: { startDate: null },
      relationships: { appPricePoint: { data: { type: "appPricePoints", id: free.id } } },
    }],
  });
  return "無料に設定";
});

// 6b. 販売地域（すべての国と地域。今後増える地域にも自動で追加）
await step("販売地域", async () => {
  try {
    await api("GET", `/v1/apps/${app.id}/appAvailabilityV2`);
    return "設定済み";
  } catch {
    // 未設定
  }
  if (!apply) return "未設定";
  const territories = await getAll("/v1/territories?limit=200");
  await api("POST", "/v2/appAvailabilities", {
    data: {
      type: "appAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        app: { data: { type: "apps", id: app.id } },
        territoryAvailabilities: { data: territories.map((t) => ({ type: "territoryAvailabilities", id: `\${${t.id}}` })) },
      },
    },
    included: territories.map((t) => ({
      type: "territoryAvailabilities",
      id: `\${${t.id}}`,
      attributes: { available: true },
      relationships: { territory: { data: { type: "territories", id: t.id } } },
    })),
  });
  return `${territories.length} の国と地域に設定`;
});

// 7. 審査メモ（連絡先は画面で入力）
await step("審査メモ", async () => {
  let detail = null;
  try {
    detail = (await api("GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)).data;
  } catch {
    detail = null;
  }
  if (detail?.attributes?.notes === listing.reviewNotes) return "設定済み";
  if (!apply) return detail ? "内容が違う" : "未設定";
  if (detail) {
    await api("PATCH", `/v1/appStoreReviewDetails/${detail.id}`, {
      data: { type: "appStoreReviewDetails", id: detail.id, attributes: { notes: listing.reviewNotes, demoAccountRequired: false } },
    });
  } else {
    await api("POST", "/v1/appStoreReviewDetails", {
      data: {
        type: "appStoreReviewDetails",
        attributes: { notes: listing.reviewNotes, demoAccountRequired: false },
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } },
      },
    });
  }
  return "設定";
});

// 8. スクリーンショット（iPhone 6.9インチ：1320x2868）
if (screenshotDir && versionLocalization) {
  await step("スクリーンショット", async () => {
    const sets = await getAll(`/v1/appStoreVersionLocalizations/${versionLocalization.id}/appScreenshotSets`);
    let set = sets.find((s) => s.attributes.screenshotDisplayType === "APP_IPHONE_67");
    if (set) {
      const existing = await getAll(`/v1/appScreenshotSets/${set.id}/appScreenshots`);
      if (existing.length > 0) return `登録済み（${existing.length}枚）`;
    }
    if (!apply) return "未登録";
    if (!set) {
      set = (await api("POST", "/v1/appScreenshotSets", {
        data: {
          type: "appScreenshotSets",
          attributes: { screenshotDisplayType: "APP_IPHONE_67" },
          relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: versionLocalization.id } } },
        },
      })).data;
    }
    const files = readdirSync(screenshotDir).filter((f) => /^\d_.*\.png$/.test(f)).sort();
    for (const file of files) {
      const bytes = readFileSync(join(screenshotDir, file));
      const reserved = (await api("POST", "/v1/appScreenshots", {
        data: {
          type: "appScreenshots",
          attributes: { fileName: basename(file), fileSize: bytes.length },
          relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set.id } } },
        },
      })).data;
      for (const op of reserved.attributes.uploadOperations) {
        const headers = Object.fromEntries((op.requestHeaders || []).map((h) => [h.name, h.value]));
        const res = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
        if (!res.ok) throw new Error(`${file} のアップロードに失敗: ${res.status}`);
      }
      await api("PATCH", `/v1/appScreenshots/${reserved.id}`, {
        data: {
          type: "appScreenshots",
          id: reserved.id,
          attributes: { uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex") },
        },
      });
    }
    return `${files.length}枚をアップロード`;
  });
}

console.log(apply ? "\n完了" : "\n（確認のみ。変更するには --apply を付けて実行）");
