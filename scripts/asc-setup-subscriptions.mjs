// App Store Connect API で、サブスクの表示名・説明・販売地域・価格を設定する。
//
// 使い方:
//   ASC_KEY_PATH=.../AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=xxxxxxxx-... node scripts/asc-setup-subscriptions.mjs [--apply] [--screenshot 画像.png]
//   --apply を付けないと、現在の状態を表示するだけで何も変更しない。
//   --screenshot を付けると、審査用スクリーンショット（購入画面）が未登録の商品にアップロードする。
//
// 鍵の中身は表示しない。秘密鍵ファイルはリポジトリに入れないこと。
import { createSign } from "node:crypto";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename } from "node:path";

const BUNDLE_ID = "com.sammy.sakuhincamera";
const GROUP_NAME_JA = "作品カメラ プレミアム";
const PLANS = {
  "com.sammy.sakuhincamera.premium.monthly": { name: "月額プラン", description: "透かしなし・全背景が使えます", priceJPY: "150" },
  "com.sammy.sakuhincamera.premium.yearly": { name: "年額プラン", description: "透かしなし・全背景が使えます", priceJPY: "1500" },
};

const apply = process.argv.includes("--apply");
const screenshotIndex = process.argv.indexOf("--screenshot");
const screenshotPath = screenshotIndex > 0 ? process.argv[screenshotIndex + 1] : null;
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
  const signature = signer.sign({ key: privateKey, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${header}.${payload}.${signature}`;
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

const app = (await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data[0];
if (!app) throw new Error("アプリが見つからない");
console.log(`アプリ: ${app.attributes.name} (${app.id})`);

const groups = await getAll(`/v1/apps/${app.id}/subscriptionGroups?limit=50`);
const group = groups[0];
console.log(`グループ: ${group.attributes.referenceName} (${group.id})`);

// 1. グループの表示名
const groupLocs = await getAll(`/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations`);
if (groupLocs.some((l) => l.attributes.locale === "ja")) {
  console.log("グループ表示名（ja）: 設定済み");
} else if (apply) {
  await api("POST", "/v1/subscriptionGroupLocalizations", {
    data: {
      type: "subscriptionGroupLocalizations",
      attributes: { locale: "ja", name: GROUP_NAME_JA },
      relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: group.id } } },
    },
  });
  console.log(`グループ表示名（ja）: 「${GROUP_NAME_JA}」を作成`);
} else {
  console.log("グループ表示名（ja）: 未設定");
}

const territories = await getAll("/v1/territories?limit=200");
const subscriptions = await getAll(`/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`);

for (const sub of subscriptions) {
  const plan = PLANS[sub.attributes.productId];
  console.log(`\n■ ${sub.attributes.name} (${sub.attributes.productId}) 状態: ${sub.attributes.state}`);
  if (!plan) {
    console.log("  想定外の商品なのでスキップ");
    continue;
  }

  // 2. 表示名と説明
  const locs = await getAll(`/v1/subscriptions/${sub.id}/subscriptionLocalizations`);
  if (locs.some((l) => l.attributes.locale === "ja")) {
    console.log("  表示名（ja）: 設定済み");
  } else if (apply) {
    await api("POST", "/v1/subscriptionLocalizations", {
      data: {
        type: "subscriptionLocalizations",
        attributes: { locale: "ja", name: plan.name, description: plan.description },
        relationships: { subscription: { data: { type: "subscriptions", id: sub.id } } },
      },
    });
    console.log(`  表示名（ja）: 「${plan.name}」を作成`);
  } else {
    console.log("  表示名（ja）: 未設定");
  }

  // 3. 販売地域（すべての国と地域。今後増える地域にも自動で追加）
  let availability = null;
  try {
    availability = (await api("GET", `/v1/subscriptions/${sub.id}/subscriptionAvailability`)).data;
  } catch {
    availability = null;
  }
  if (availability) {
    console.log("  販売地域: 設定済み");
  } else if (apply) {
    await api("POST", "/v1/subscriptionAvailabilities", {
      data: {
        type: "subscriptionAvailabilities",
        attributes: { availableInNewTerritories: true },
        relationships: {
          subscription: { data: { type: "subscriptions", id: sub.id } },
          availableTerritories: { data: territories.map((t) => ({ type: "territories", id: t.id })) },
        },
      },
    });
    console.log(`  販売地域: ${territories.length} の国と地域に設定`);
  } else {
    console.log("  販売地域: 未設定");
  }

  // 4. 審査用スクリーンショット
  let screenshot = null;
  try {
    screenshot = (await api("GET", `/v1/subscriptions/${sub.id}/appStoreReviewScreenshot`)).data;
  } catch {
    screenshot = null;
  }
  if (screenshot) {
    console.log("  審査用スクリーンショット: 登録済み");
  } else if (apply && screenshotPath) {
    const bytes = readFileSync(screenshotPath);
    const reserved = (await api("POST", "/v1/subscriptionAppStoreReviewScreenshots", {
      data: {
        type: "subscriptionAppStoreReviewScreenshots",
        attributes: { fileName: basename(screenshotPath), fileSize: bytes.length },
        relationships: { subscription: { data: { type: "subscriptions", id: sub.id } } },
      },
    })).data;
    for (const op of reserved.attributes.uploadOperations) {
      const headers = Object.fromEntries((op.requestHeaders || []).map((h) => [h.name, h.value]));
      const res = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
      if (!res.ok) throw new Error(`スクリーンショットのアップロードに失敗: ${res.status}`);
    }
    await api("PATCH", `/v1/subscriptionAppStoreReviewScreenshots/${reserved.id}`, {
      data: {
        type: "subscriptionAppStoreReviewScreenshots",
        id: reserved.id,
        attributes: { uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex") },
      },
    });
    console.log("  審査用スクリーンショット: アップロード");
  } else {
    console.log("  審査用スクリーンショット: 未登録");
  }

  // 5. 価格（日本の価格に合わせて全地域を自動換算）
  const prices = await getAll(`/v1/subscriptions/${sub.id}/prices?limit=200`);
  if (prices.length >= territories.length) {
    console.log(`  価格: 設定済み（${prices.length} 地域）`);
    continue;
  }
  const jpPoints = await getAll(`/v1/subscriptions/${sub.id}/pricePoints?filter[territory]=JPN&limit=200`);
  const jpPoint = jpPoints.find((p) => Number(p.attributes.customerPrice) === Number(plan.priceJPY));
  if (!jpPoint) throw new Error(`日本の価格 ¥${plan.priceJPY} の価格ポイントが見つからない`);
  const equalizations = await getAll(`/v1/subscriptionPricePoints/${jpPoint.id}/equalizations?limit=200&include=territory`);
  const pointByTerritory = new Map([["JPN", jpPoint.id]]);
  for (const point of equalizations) {
    const territory = point.relationships?.territory?.data?.id;
    if (territory) pointByTerritory.set(territory, point.id);
  }
  console.log(`  価格: 日本 ¥${plan.priceJPY} → ${pointByTerritory.size} 地域ぶんの価格ポイント`);
  if (!apply) continue;

  const done = new Set(prices.map((p) => p.relationships?.territory?.data?.id).filter(Boolean));
  let created = 0;
  for (const [territory, pointId] of pointByTerritory) {
    if (done.has(territory)) continue;
    await api("POST", "/v1/subscriptionPrices", {
      data: {
        type: "subscriptionPrices",
        attributes: { preserveCurrentPrice: false },
        relationships: {
          subscription: { data: { type: "subscriptions", id: sub.id } },
          subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: pointId } },
          territory: { data: { type: "territories", id: territory } },
        },
      },
    });
    created += 1;
  }
  console.log(`  価格: ${created} 地域を設定`);
}

console.log(apply ? "\n完了" : "\n（確認のみ。変更するには --apply を付けて実行）");
