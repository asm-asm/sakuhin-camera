// App Store Connect API で、プレミアム（買い切り・非消耗型のアプリ内課金）を作って設定する。
//
// 使い方:
//   ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... node scripts/asc-setup-iap.mjs [--apply] [--screenshot 購入画面.png]
//   --apply を付けないと、現在の状態を表示するだけで何も変更しない。
import { createHash, createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename } from "node:path";

const BUNDLE_ID = "com.sammy.sakuhincamera";
const PRODUCT_ID = "com.sammy.sakuhincamera.premium.lifetime";
const REFERENCE_NAME = "プレミアム（買い切り）";
const DISPLAY_NAME = "プレミアム";
const DESCRIPTION = "透かしなし・すべての背景が使えます";
const PRICE_JPY = 480;

const apply = process.argv.includes("--apply");
const shotIndex = process.argv.indexOf("--screenshot");
const screenshotPath = shotIndex > 0 ? process.argv[shotIndex + 1] : null;

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

// 1. 商品
let iap = (await getAll(`/v1/apps/${app.id}/inAppPurchasesV2?limit=200`)).find((p) => p.attributes.productId === PRODUCT_ID);
if (iap) {
  console.log(`商品: あり（${iap.attributes.inAppPurchaseType} / 状態 ${iap.attributes.state}）`);
} else if (apply) {
  iap = (await api("POST", "/v2/inAppPurchases", {
    data: {
      type: "inAppPurchases",
      attributes: { name: REFERENCE_NAME, productId: PRODUCT_ID, inAppPurchaseType: "NON_CONSUMABLE", familySharable: false },
      relationships: { app: { data: { type: "apps", id: app.id } } },
    },
  })).data;
  console.log(`商品: 「${REFERENCE_NAME}」を作成（非消耗型）`);
} else {
  console.log("商品: 未作成");
  console.log("\n（確認のみ。変更するには --apply を付けて実行）");
  process.exit(0);
}

// 2. 表示名と説明
await step("表示名（ja）", async () => {
  const locs = await getAll(`/v2/inAppPurchases/${iap.id}/inAppPurchaseLocalizations`);
  if (locs.some((l) => l.attributes.locale === "ja")) return "設定済み";
  if (!apply) return "未設定";
  await api("POST", "/v1/inAppPurchaseLocalizations", {
    data: {
      type: "inAppPurchaseLocalizations",
      attributes: { locale: "ja", name: DISPLAY_NAME, description: DESCRIPTION },
      relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap.id } } },
    },
  });
  return `「${DISPLAY_NAME}」を作成`;
});

// 3. 価格（日本 ¥480 を基準に、他の国は自動換算）
await step("価格", async () => {
  try {
    const schedule = (await api("GET", `/v2/inAppPurchases/${iap.id}/iapPriceSchedule`)).data;
    const prices = await api("GET", `/v1/inAppPurchasePriceSchedules/${schedule.id}/manualPrices`);
    if (prices.data.length > 0) return "設定済み";
  } catch {
    // 未設定
  }
  if (!apply) return "未設定";
  const points = await getAll(`/v2/inAppPurchases/${iap.id}/pricePoints?filter[territory]=JPN&limit=200`);
  const point = points.find((p) => Number(p.attributes.customerPrice) === PRICE_JPY);
  if (!point) throw new Error(`日本の価格 ¥${PRICE_JPY} が見つからない`);
  await api("POST", "/v1/inAppPurchasePriceSchedules", {
    data: {
      type: "inAppPurchasePriceSchedules",
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap.id } },
        baseTerritory: { data: { type: "territories", id: "JPN" } },
        manualPrices: { data: [{ type: "inAppPurchasePrices", id: "${price}" }] },
      },
    },
    included: [{
      type: "inAppPurchasePrices",
      id: "${price}",
      attributes: { startDate: null },
      relationships: { inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point.id } } },
    }],
  });
  return `日本 ¥${PRICE_JPY}（他の国は自動換算）に設定`;
});

// 4. 販売地域
await step("販売地域", async () => {
  try {
    await api("GET", `/v2/inAppPurchases/${iap.id}/inAppPurchaseAvailability`);
    return "設定済み";
  } catch {
    // 未設定
  }
  if (!apply) return "未設定";
  const territories = await getAll("/v1/territories?limit=200");
  await api("POST", "/v1/inAppPurchaseAvailabilities", {
    data: {
      type: "inAppPurchaseAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap.id } },
        availableTerritories: { data: territories.map((t) => ({ type: "territories", id: t.id })) },
      },
    },
  });
  return `${territories.length} の国と地域に設定`;
});

// 5. 審査用スクリーンショット（購入画面）
await step("審査用スクリーンショット", async () => {
  try {
    const existing = (await api("GET", `/v2/inAppPurchases/${iap.id}/appStoreReviewScreenshot`)).data;
    if (existing) return "登録済み";
  } catch {
    // 未登録
  }
  if (!apply || !screenshotPath) return "未登録";
  const bytes = readFileSync(screenshotPath);
  const reserved = (await api("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", {
    data: {
      type: "inAppPurchaseAppStoreReviewScreenshots",
      attributes: { fileName: basename(screenshotPath), fileSize: bytes.length },
      relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap.id } } },
    },
  })).data;
  for (const op of reserved.attributes.uploadOperations) {
    const headers = Object.fromEntries((op.requestHeaders || []).map((h) => [h.name, h.value]));
    const res = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
    if (!res.ok) throw new Error(`アップロードに失敗: ${res.status}`);
  }
  await api("PATCH", `/v1/inAppPurchaseAppStoreReviewScreenshots/${reserved.id}`, {
    data: {
      type: "inAppPurchaseAppStoreReviewScreenshots",
      id: reserved.id,
      attributes: { uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex") },
    },
  });
  return "アップロード";
});

const latest = (await api("GET", `/v2/inAppPurchases/${iap.id}`)).data;
console.log(`\n状態: ${latest.attributes.state}`);
console.log(apply ? "完了" : "（確認のみ。変更するには --apply を付けて実行）");
