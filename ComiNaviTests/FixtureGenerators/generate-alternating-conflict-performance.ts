import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import {
  applyPlanOperation,
  type PlanOperation,
} from "../../../server/src/lib/server/plan-document";

const require = createRequire(
  new URL("../../../server/package.json", import.meta.url),
);
const Automerge = require("@automerge/automerge");

const fixturePath =
  "../ios/ComiNaviTests/Fixtures/automerge-conflict-performance-v1.json";
const bootstrapPath =
  "../ios/ComiNaviTests/Fixtures/automerge-bootstrap-v1.json";
const actorID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const actorUserID = "0123456789abcdef0123456789abcdef";

const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as Record<
  string,
  unknown
>;
const bootstrap = JSON.parse(readFileSync(bootstrapPath, "utf8")) as {
  document: string;
};
let current = Automerge.clone(
  Automerge.load(Buffer.from(bootstrap.document, "base64url")),
  { actor: actorID },
);

let operationIndex = 1;
current = change(current, operationUUID(operationIndex++), {
  type: "shared_plan.circle.presence.v1",
  actorUserID,
  payload: { v: 1, wcID: 9001, state: "active" },
});
operationIndex = 20_000;
for (let cycle = 0; cycle < 3_332; cycle += 1) {
  current = change(current, operationUUID(operationIndex++), {
    type: "shared_plan.circle.presence.v1",
    actorUserID,
    payload: { v: 1, wcID: 9001, state: "removed" },
  });
  current = change(current, operationUUID(operationIndex++), {
    type: "shared_plan.circle.presence.v1",
    actorUserID,
    payload: { v: 1, wcID: 9001, state: "active" },
  });
  current = change(current, operationUUID(operationIndex++), {
    type: "shared_plan.circle.communication.set.v1",
    actorUserID,
    payload: {
      v: 1,
      wcID: 9001,
      key: "meeting.place",
      value: cycle % 2 === 0 ? "東" : "西",
    },
  });
}
for (const value of ["中央", "北", "南"] as const) {
  current = change(current, operationUUID(operationIndex++), {
    type: "shared_plan.circle.communication.set.v1",
    actorUserID,
    payload: { v: 1, wcID: 9001, key: "meeting.place", value },
  });
}

const operations = Object.values(current.operations);
fixture.alternatingAt10000 = {
  document: Buffer.from(Automerge.save(current)).toString("base64url"),
  heads: Automerge.getHeads(current).sort(),
  operationCount: operations.length,
  historyCount: Automerge.getHistory(current).length,
  retainedOperationPayloadUTF8Bytes: operations.reduce(
    (total, operation) =>
      total + Buffer.byteLength(canonicalJSON(operation.payload), "utf8"),
    0,
  ),
};
writeFileSync(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`);

function change(
  document: any,
  operationID: string,
  operation: PlanOperation,
): any {
  return Automerge.change(
    document,
    {
      message: `operation:${operationID}`,
      time: 1_740_000_000 + Number.parseInt(operationID.slice(-12), 16),
    },
    (draft) => applyPlanOperation(draft, operationID, operation),
  );
}

function operationUUID(index: number): string {
  return `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
}

function canonicalJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  return `{${Object.entries(value)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, child]) => `${JSON.stringify(key)}:${canonicalJSON(child)}`)
    .join(",")}}`;
}
