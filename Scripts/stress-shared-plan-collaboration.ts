#!/usr/bin/env -S pnpm exec tsx

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

import {
  PlanDocumentError,
  applyPlanOperation,
  canonicalJSON,
  detectPlanConflicts,
  type PlanActorAuthority,
  type PlanDocument,
  type PlanMutationValidationContext,
  type PlanOperation,
  validatePlanMutation,
} from "../../server/src/lib/server/plan-document";

const serverDirectory = resolve(__dirname, "../../server");
const require = createRequire(resolve(serverDirectory, "package.json"));
const Automerge = require("@automerge/automerge") as typeof import("@automerge/automerge");

const planID = "11111111-1111-4111-8111-111111111111";
const comiketNo = 108;
const scenario = stringArgument("scenario", "random");
const actorCount = integerArgument("actors", 4);
const seedCount = integerArgument("seeds", 1_000);
const stepsPerSeed = integerArgument("steps", 120);
const progressEvery = integerArgument("progress-every", 100);
const failureReportLimit = integerArgument("failure-report-limit", 3);
const reconnectsPerThousand = integerArgument("reconnects-per-thousand", 40);

if (
  scenario !== "random" &&
  scenario !== "circle-parent-conflict" &&
  scenario !== "need-parent-conflict" &&
  scenario !== "stale-multihead"
) {
  throw new Error(
    "--scenario must be random, circle-parent-conflict, need-parent-conflict, " +
      "or stale-multihead",
  );
}

if (actorCount < 1 || actorCount > 8) {
  throw new Error("--actors must be between 1 and 8");
}
if (
  seedCount < 1 ||
  stepsPerSeed < 1 ||
  progressEvery < 1 ||
  failureReportLimit < 0 ||
  reconnectsPerThousand < 0 ||
  reconnectsPerThousand > 100
) {
  throw new Error(
    "--seeds, --steps, and --progress-every must be positive; " +
      "--failure-report-limit must be non-negative; " +
      "--reconnects-per-thousand must be between 0 and 100",
  );
}

interface Peer {
  readonly index: number;
  readonly actorID: string;
  readonly userPublicID: string;
  document: Automerge.Doc<PlanDocument>;
  clientSyncState: Automerge.SyncState;
  serverSyncState: Automerge.SyncState;
  authored: number;
}

interface TraceEntry {
  readonly step: number;
  readonly action: string;
  readonly peer?: number;
  readonly operationID?: string;
  readonly operationType?: string;
  readonly heads?: string[];
}

interface Counters {
  authored: number;
  skippedAuthorAttempts: number;
  clientFrames: number;
  serverFrames: number;
  validatedFrames: number;
  validatedChanges: number;
  reconnects: number;
}

class CollaborationRun {
  private readonly random: () => number;
  private readonly authorities: Map<string, PlanActorAuthority>;
  private readonly activeMembers: Set<string>;
  private readonly trace: TraceEntry[] = [];
  private operationSequence = 10_000;
  private currentStep = -1;
  private lastValidationAttempt: Record<string, unknown> | null = null;
  private server: Automerge.Doc<PlanDocument>;
  readonly peers: Peer[];
  readonly counters: Counters = {
    authored: 0,
    skippedAuthorAttempts: 0,
    clientFrames: 0,
    serverFrames: 0,
    validatedFrames: 0,
    validatedChanges: 0,
    reconnects: 0,
  };

  private constructor(
    readonly seed: number,
    server: Automerge.Doc<PlanDocument>,
    peers: Peer[],
    authorities: Map<string, PlanActorAuthority>,
    activeMembers: Set<string>,
  ) {
    this.random = mulberry32(seed);
    this.server = server;
    this.peers = peers;
    this.authorities = authorities;
    this.activeMembers = activeMembers;
  }

  static async create(seed: number): Promise<CollaborationRun> {
    const actors = Array.from({ length: actorCount }, (_, index) => ({
      actorID: (index + 10).toString(16).repeat(32),
      userPublicID: (index + 1).toString(16).repeat(32),
      replicaID: uuid(1_000 + index),
    }));
    const authorities = new Map<string, PlanActorAuthority>(
      actors.map((actor, index) => [
        actor.actorID,
        {
          actorID: actor.actorID,
          userID: index + 1,
          userPublicID: actor.userPublicID,
          replicaID: actor.replicaID,
          authVersion: 1,
          membershipEpoch: 1,
        },
      ]),
    );
    const activeMembers = new Set(actors.map((actor) => actor.userPublicID));
    let server = loadBootstrap(actors[0]!.actorID);

    const initialOperations: PlanOperation[] = [
      circlePresence(actors[0]!.userPublicID, 9_001, "active"),
      circlePresence(actors[0]!.userPublicID, 9_002, "active"),
      createNeed(
        actors[0]!.userPublicID,
        9_001,
        uuid(101),
        "新刊セット",
        1,
      ),
      createNeed(
        actors[0]!.userPublicID,
        9_001,
        uuid(102),
        "アクリルキーホルダー",
        1,
      ),
      createNeed(
        actors[0]!.userPublicID,
        9_002,
        uuid(103),
        "合同誌",
        2,
      ),
    ];
    for (const [index, operation] of initialOperations.entries()) {
      const operationID = uuid(index + 1);
      const candidate = changeAs(
        server,
        actors[0]!.actorID,
        operationID,
        operation,
        index + 1,
      );
      server = (
        await validatePlanMutation(server, candidate, {
          planID,
          comiketNo,
          frameActorID: actors[0]!.actorID,
          frameUserPublicID: actors[0]!.userPublicID,
          actors: authorities,
          activeMemberPublicIDs: activeMembers,
          membershipEpoch: 1,
        })
      ).document;
    }

    const peers = actors.map((actor, index): Peer => ({
      index,
      actorID: actor.actorID,
      userPublicID: actor.userPublicID,
      document: Automerge.clone(server, { actor: actor.actorID }),
      clientSyncState: Automerge.initSyncState(),
      serverSyncState: Automerge.initSyncState(),
      authored: 0,
    }));
    const run = new CollaborationRun(
      seed,
      server,
      peers,
      authorities,
      activeMembers,
    );
    for (const peer of peers) await run.synchronizeUntilQuiet(peer);
    return run;
  }

  async execute(steps: number): Promise<void> {
    for (let step = 0; step < steps; step += 1) {
      this.currentStep = step;
      const roll = this.random();
      const peer = this.randomPeer();
      if (roll < 0.58) {
        await this.authorRandomOperation(peer, step);
      } else if (roll < 0.76) {
        await this.exchange(peer);
      } else if (roll < 0.88) {
        await this.pushServer(peer);
      } else if (roll < 1 - reconnectsPerThousand / 1_000) {
        await this.synchronizeUntilQuiet(peer);
      } else {
        this.reconnect(peer, step);
      }
    }

    for (let pass = 0; pass < 8; pass += 1) {
      for (const peer of this.peers) await this.synchronizeUntilQuiet(peer);
    }
    const serverHeads = sortedHeads(this.server);
    for (const peer of this.peers) {
      assert.deepEqual(
        sortedHeads(peer.document),
        serverHeads,
        `seed ${this.seed}: peer ${peer.index} did not converge`,
      );
    }
  }

  failureReport(error: unknown): Record<string, unknown> {
    return {
      seed: this.seed,
      step: this.currentStep,
      error:
        error instanceof PlanDocumentError
          ? { name: error.constructor.name, code: error.code, details: error.details }
          : error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error),
      counters: this.counters,
      serverHeads: sortedHeads(this.server),
      peers: this.peers.map((peer) => ({
        index: peer.index,
        actorID: peer.actorID,
        authored: peer.authored,
        heads: sortedHeads(peer.document),
      })),
      lastValidationAttempt: this.lastValidationAttempt,
      recentTrace: this.trace.slice(-80),
    };
  }

  private async authorRandomOperation(peer: Peer, step: number): Promise<void> {
    for (let attempt = 0; attempt < 24; attempt += 1) {
      const operation = this.randomOperation(peer);
      if (
        await conflictBlocksOrdinaryClientOperation(peer.document, operation)
      ) {
        continue;
      }
      const operationID = uuid(this.operationSequence++);
      try {
        peer.document = changeAs(
          peer.document,
          peer.actorID,
          operationID,
          operation,
          1_800_000_000 + this.seed * stepsPerSeed + step,
        );
        peer.authored += 1;
        this.counters.authored += 1;
        this.record({
          step,
          action: "author",
          peer: peer.index,
          operationID,
          operationType: operation.type,
          heads: sortedHeads(peer.document),
        });
        return;
      } catch (error) {
        if (!(error instanceof PlanDocumentError)) throw error;
      }
    }
    this.counters.skippedAuthorAttempts += 1;
    this.record({ step, action: "author-skipped", peer: peer.index });
  }

  private randomOperation(peer: Peer): PlanOperation {
    const activeCircles = Object.values(peer.document.circles).filter(
      (circle) => circle?.presence.state === "active",
    );
    if (activeCircles.length === 0) {
      return circlePresence(
        peer.userPublicID,
        9_001 + randomInteger(this.random, 6),
        "active",
      );
    }

    const circle = choose(this.random, activeCircles)!;
    const wcID = circle.WCID;
    const activeNeeds = Object.entries(circle.needs).filter(
      ([, need]) => need?.presence.state === "active",
    );
    const roll = this.random();
    if (roll < 0.05) {
      return circlePresence(
        peer.userPublicID,
        9_001 + randomInteger(this.random, 8),
        "active",
      );
    }
    if (roll < 0.13) {
      return circlePresence(peer.userPublicID, wcID, "removed");
    }
    if (roll < 0.28) {
      const scalars = Array.from(circle.memo);
      const index = randomInteger(this.random, scalars.length + 1);
      const deleteCount =
        scalars.length > index && this.random() < 0.35 ? 1 : 0;
      return {
        type: "shared_plan.circle.memo.splice.v1",
        actorUserID: peer.userPublicID,
        payload: {
          v: 1,
          wcID,
          index,
          deleteCount,
          text: choose(this.random, ["東", "西", "新刊", "e\u0301", "👩‍👩‍👧‍👦"])!,
        },
      };
    }
    if (roll < 0.43 || activeNeeds.length === 0) {
      const needIndex = 101 + randomInteger(this.random, 18);
      return createNeed(
        peer.userPublicID,
        wcID,
        uuid(needIndex),
        `品物-${needIndex}`,
        1 + randomInteger(this.random, 4),
      );
    }

    const [needID, need] = choose(this.random, activeNeeds)!;
    if (roll < 0.53) {
      return {
        type: "shared_plan.need.delete.v1",
        actorUserID: peer.userPublicID,
        payload: { v: 1, wcID, needID },
      };
    }
    if (roll < 0.67) {
      return {
        type: "shared_plan.need.wanted_quantity.v1",
        actorUserID: peer.userPublicID,
        payload: {
          v: 1,
          wcID,
          needID,
          wantedQuantity: differentQuantity(this.random, need.wantedQuantity),
        },
      };
    }
    if (roll < 0.81) {
      const buyer = choose(this.random, this.peers)!;
      return {
        type: "shared_plan.need.buyer_allocation.v1",
        actorUserID: peer.userPublicID,
        payload: {
          v: 1,
          wcID,
          needID,
          buyerUserID: buyer.userPublicID,
          quantity: differentQuantity(
            this.random,
            need.buyerAllocations[buyer.userPublicID] ?? 0,
          ),
        },
      };
    }
    if (roll < 0.91) {
      return {
        type: "shared_plan.need.fulfilled_quantity.v1",
        actorUserID: peer.userPublicID,
        payload: {
          v: 1,
          wcID,
          needID,
          fulfilledQuantity: differentQuantity(
            this.random,
            need.fulfilledQuantity,
          ),
        },
      };
    }
    const key = choose(this.random, ["meeting.status", "pickup.zone", "day.note"])!;
    return {
      type: "shared_plan.circle.communication.set.v1",
      actorUserID: peer.userPublicID,
      payload: {
        v: 1,
        wcID,
        key,
        value: choose(this.random, [null, true, false, 0, 1, "東", "西"])!,
      },
    };
  }

  private async exchange(peer: Peer): Promise<boolean> {
    let clientMessage: Uint8Array | null;
    [peer.clientSyncState, clientMessage] = Automerge.generateSyncMessage(
      peer.document,
      peer.clientSyncState,
    );
    if (!clientMessage) return this.pushServer(peer);

    this.counters.clientFrames += 1;
    const before = this.server;
    let candidate: Automerge.Doc<PlanDocument>;
    let receivedState: Automerge.SyncState;
    [candidate, receivedState] = Automerge.receiveSyncMessage(
      Automerge.clone(this.server),
      peer.serverSyncState,
      clientMessage,
    );
    const changes = Automerge.getChanges(before, candidate);
    if (changes.length > 0) {
      this.lastValidationAttempt = {
        peer: peer.index,
        currentHeads: sortedHeads(before),
        candidateHeads: sortedHeads(candidate),
        currentParentConflicts: parentConflictSummary(before),
        candidateParentConflicts: parentConflictSummary(candidate),
        incomingChanges: await Promise.all(changes.map(async (bytes) => {
          const decoded = Automerge.decodeChange(bytes);
          const operationID = decoded.message?.startsWith("operation:")
            ? decoded.message.slice("operation:".length)
            : null;
          const causalDocument = Automerge.view(candidate, decoded.deps);
          const operation =
            operationID === null ? null : candidate.operations[operationID];
          const targetCircle = operation
            ? causalDocument.circles[String(operation.payload.wcID)]
            : null;
          const targetNeedID =
            operation && "needID" in operation.payload
              ? String(operation.payload.needID)
              : null;
          return {
            hash: decoded.hash,
            actor: decoded.actor,
            dependencies: decoded.deps.slice().sort(),
            message: decoded.message,
            causalHeads: sortedHeads(causalDocument),
            causalParentConflicts: parentConflictSummary(causalDocument),
            causalConflicts: await detectPlanConflicts(causalDocument),
            exactReplay:
              operationID === null || operation == null
                ? null
                : compareExactReplay(
                    causalDocument,
                    decoded,
                    operationID,
                    operation,
                  ),
            causalTarget: targetCircle
              ? {
                  presence: targetCircle.presence,
                  presenceConflicts: Object.keys(
                    Automerge.getConflicts(targetCircle, "presence") ?? {},
                  ),
                  need: targetNeedID ? targetCircle.needs[targetNeedID] : null,
                  needPresenceConflicts:
                    targetNeedID && targetCircle.needs[targetNeedID]
                      ? Object.keys(
                          Automerge.getConflicts(
                            targetCircle.needs[targetNeedID]!,
                            "presence",
                          ) ?? {},
                        )
                      : [],
                }
              : null,
            operation,
          };
        })),
      };
      const validated = await validatePlanMutation(
        before,
        candidate,
        this.validationContext(peer),
      );
      this.server = validated.document;
      this.counters.validatedFrames += 1;
      this.counters.validatedChanges += validated.operations.length;
      this.record({
        step: this.currentStep,
        action: "validated-client-frame",
        peer: peer.index,
        heads: sortedHeads(this.server),
      });
    }
    peer.serverSyncState = receivedState;
    await this.pushServer(peer);
    return true;
  }

  private async pushServer(peer: Peer): Promise<boolean> {
    let serverMessage: Uint8Array | null;
    [peer.serverSyncState, serverMessage] = Automerge.generateSyncMessage(
      this.server,
      peer.serverSyncState,
    );
    if (!serverMessage) return false;
    this.counters.serverFrames += 1;
    [peer.document, peer.clientSyncState] = Automerge.receiveSyncMessage(
      Automerge.clone(peer.document, { actor: peer.actorID }),
      peer.clientSyncState,
      serverMessage,
    );
    this.record({
      step: this.currentStep,
      action: "server-frame",
      peer: peer.index,
      heads: sortedHeads(peer.document),
    });
    return true;
  }

  private async synchronizeUntilQuiet(peer: Peer): Promise<void> {
    for (let round = 0; round < 30; round += 1) {
      const activity = await this.exchange(peer);
      if (!activity) return;
    }
    throw new Error(`seed ${this.seed}: peer ${peer.index} sync did not quiesce`);
  }

  private reconnect(peer: Peer, step: number): void {
    peer.document = Automerge.clone(
      Automerge.load<PlanDocument>(Automerge.save(peer.document)),
      { actor: peer.actorID },
    );
    peer.clientSyncState = Automerge.initSyncState();
    peer.serverSyncState = Automerge.initSyncState();
    this.counters.reconnects += 1;
    this.record({ step, action: "reconnect", peer: peer.index });
  }

  private validationContext(peer: Peer): PlanMutationValidationContext {
    return {
      planID,
      comiketNo,
      frameActorID: peer.actorID,
      frameUserPublicID: peer.userPublicID,
      actors: this.authorities,
      activeMemberPublicIDs: this.activeMembers,
      membershipEpoch: 1,
    };
  }

  private randomPeer(): Peer {
    return choose(this.random, this.peers)!;
  }

  private record(entry: TraceEntry): void {
    this.trace.push(entry);
    if (this.trace.length > 240) this.trace.shift();
  }
}

void main();

async function main(): Promise<void> {
  if (scenario === "circle-parent-conflict") {
    await reproduceCircleParentConflict();
    return;
  }
  if (scenario === "need-parent-conflict") {
    await reproduceNeedParentConflict();
    return;
  }
  if (scenario === "stale-multihead") {
    await reproduceStaleMultiheadDependencyMismatch();
    return;
  }

  const totals: Counters = {
    authored: 0,
    skippedAuthorAttempts: 0,
    clientFrames: 0,
    serverFrames: 0,
    validatedFrames: 0,
    validatedChanges: 0,
    reconnects: 0,
  };
  const continueOnError = process.argv.includes("--continue-on-error");
  const failures: Array<Record<string, unknown>> = [];
  const startedAt = performance.now();
  for (let seed = 1; seed <= seedCount; seed += 1) {
    const run = await CollaborationRun.create(seed);
    try {
      await run.execute(stepsPerSeed);
    } catch (error) {
      const report = run.failureReport(error);
      failures.push(report);
      if (failures.length <= failureReportLimit) {
        console.error(JSON.stringify(report, null, 2));
      }
      addCounters(totals, run.counters);
      if (!continueOnError) {
        process.exitCode = 1;
        break;
      }
      continue;
    }
    addCounters(totals, run.counters);
    if (seed % progressEvery === 0 || seed === seedCount) {
      console.log(
        JSON.stringify({
          completedSeeds: seed,
          seedCount,
          stepsPerSeed,
          actorCount,
          elapsedSeconds: Number(
            ((performance.now() - startedAt) / 1_000).toFixed(2),
          ),
          totals,
        }),
      );
    }
  }

  if (!process.exitCode || continueOnError) {
    console.log(
      JSON.stringify({
        result: failures.length === 0 ? "pass" : "reproduced",
        seedCount,
        completedSeeds: continueOnError ? seedCount : seedCount - failures.length,
        failedSeeds: failures.length,
        stepsPerSeed,
        actorCount,
        elapsedSeconds: Number(
          ((performance.now() - startedAt) / 1_000).toFixed(2),
        ),
        totals,
      }),
    );
    if (failures.length > 0) process.exitCode = 1;
  }
}

async function reproduceCircleParentConflict(): Promise<void> {
  const actorA = {
    actorID: "a".repeat(32),
    userPublicID: "1".repeat(32),
    replicaID: uuid(8_001),
  };
  const actorB = {
    actorID: "b".repeat(32),
    userPublicID: "2".repeat(32),
    replicaID: uuid(8_002),
  };
  const actors = new Map<string, PlanActorAuthority>([
    [
      actorA.actorID,
      {
        ...actorA,
        userID: 1,
        authVersion: 1,
        membershipEpoch: 1,
      },
    ],
    [
      actorB.actorID,
      {
        ...actorB,
        userID: 2,
        authVersion: 1,
        membershipEpoch: 1,
      },
    ],
  ]);
  const activeMemberPublicIDs = new Set([
    actorA.userPublicID,
    actorB.userPublicID,
  ]);
  const context = (actor: typeof actorA): PlanMutationValidationContext => ({
    planID,
    comiketNo,
    frameActorID: actor.actorID,
    frameUserPublicID: actor.userPublicID,
    actors,
    activeMemberPublicIDs,
    membershipEpoch: 1,
  });

  const base = loadBootstrap(actorA.actorID);
  const addA = changeAs(
    base,
    actorA.actorID,
    uuid(8_101),
    circlePresence(actorA.userPublicID, 9_001, "active"),
    1_900_000_001,
  );
  const addB = changeAs(
    base,
    actorB.actorID,
    uuid(8_102),
    circlePresence(actorB.userPublicID, 9_001, "active"),
    1_900_000_002,
  );
  const acceptedA = (
    await validatePlanMutation(base, addA, context(actorA))
  ).document;
  const acceptedBoth = (
    await validatePlanMutation(
      acceptedA,
      Automerge.merge(
        Automerge.clone(acceptedA, { actor: actorB.actorID }),
        addB,
      ),
      context(actorB),
    )
  ).document;
  const parentConflicts = Object.keys(
    Automerge.getConflicts(acceptedBoth.circles, "9001") ?? {},
  );
  assert.equal(parentConflicts.length, 2);

  // This deliberately mirrors SharedPlanDocument.setCirclePresence: it edits
  // Automerge's visible parent and does not count competing circle parents.
  const removeBeforePull = changeCirclePresenceLikeSwift(
    acceptedA,
    actorA.actorID,
    actorA.userPublicID,
    uuid(8_103),
    9_001,
    "removed",
    1_900_000_003,
  );
  const staleAccepted = await validatePlanMutation(
    acceptedBoth,
    Automerge.merge(
      Automerge.clone(acceptedBoth, { actor: actorA.actorID }),
      removeBeforePull,
    ),
    context(actorA),
  );
  assert.equal(staleAccepted.operations.length, 1);

  const removeAfterPull = changeCirclePresenceLikeSwift(
    acceptedBoth,
    actorA.actorID,
    actorA.userPublicID,
    uuid(8_104),
    9_001,
    "removed",
    1_900_000_004,
  );
  const postPullChange = Automerge.decodeChange(
    Automerge.getLastLocalChange(removeAfterPull)!,
  );
  let rejection: Record<string, unknown> | null = null;
  try {
    await validatePlanMutation(acceptedBoth, removeAfterPull, context(actorA));
  } catch (error) {
    if (!(error instanceof PlanDocumentError)) throw error;
    rejection = { code: error.code, details: error.details };
  }
  assert.deepEqual(rejection, {
    code: "invalid_plan_operation",
    details: {
      reason: "exact_change_proof",
      recovery: "export_and_rebuild_local_copy",
      localChangesPreserved: true,
      supportCode: "SP-OP-302",
    },
  });

  console.log(
    JSON.stringify(
      {
        result: "reproduced",
        scenario,
        parentCandidates: parentConflicts.length,
        removeBeforePeerPull: {
          result: "accepted",
          operations: staleAccepted.operations.length,
          dependencies: Automerge.decodeChange(
            Automerge.getLastLocalChange(removeBeforePull)!,
          ).deps,
        },
        removeAfterPeerPull: {
          result: "rejected",
          dependencies: postPullChange.deps,
          rejection,
        },
      },
      null,
      2,
    ),
  );
}

async function reproduceNeedParentConflict(): Promise<void> {
  const actorA = {
    actorID: "a".repeat(32),
    userPublicID: "1".repeat(32),
    replicaID: uuid(8_201),
  };
  const actorB = {
    actorID: "b".repeat(32),
    userPublicID: "2".repeat(32),
    replicaID: uuid(8_202),
  };
  const actors = new Map<string, PlanActorAuthority>([
    [
      actorA.actorID,
      {
        ...actorA,
        userID: 1,
        authVersion: 1,
        membershipEpoch: 1,
      },
    ],
    [
      actorB.actorID,
      {
        ...actorB,
        userID: 2,
        authVersion: 1,
        membershipEpoch: 1,
      },
    ],
  ]);
  const activeMemberPublicIDs = new Set([
    actorA.userPublicID,
    actorB.userPublicID,
  ]);
  const context = (actor: typeof actorA): PlanMutationValidationContext => ({
    planID,
    comiketNo,
    frameActorID: actor.actorID,
    frameUserPublicID: actor.userPublicID,
    actors,
    activeMemberPublicIDs,
    membershipEpoch: 1,
  });
  const needID = uuid(8_250);

  const bootstrap = loadBootstrap(actorA.actorID);
  const circleCandidate = changeAs(
    bootstrap,
    actorA.actorID,
    uuid(8_251),
    circlePresence(actorA.userPublicID, 9_001, "active"),
    1_900_001_001,
  );
  const circleBase = (
    await validatePlanMutation(bootstrap, circleCandidate, context(actorA))
  ).document;
  const needA = changeAs(
    circleBase,
    actorA.actorID,
    uuid(8_252),
    createNeed(actorA.userPublicID, 9_001, needID, "同じ品物", 1),
    1_900_001_002,
  );
  const needB = changeAs(
    circleBase,
    actorB.actorID,
    uuid(8_253),
    createNeed(actorB.userPublicID, 9_001, needID, "同じ品物", 1),
    1_900_001_003,
  );
  const deletedB = changeAs(
    needB,
    actorB.actorID,
    uuid(8_254),
    {
      type: "shared_plan.need.delete.v1",
      actorUserID: actorB.userPublicID,
      payload: { v: 1, wcID: 9_001, needID },
    },
    1_900_001_004,
  );
  const acceptedA = (
    await validatePlanMutation(circleBase, needA, context(actorA))
  ).document;
  const acceptedBoth = (
    await validatePlanMutation(
      acceptedA,
      Automerge.merge(
        Automerge.clone(acceptedA, { actor: actorB.actorID }),
        deletedB,
      ),
      context(actorB),
    )
  ).document;
  const circle = acceptedBoth.circles["9001"]!;
  const needParentConflicts = Object.keys(
    Automerge.getConflicts(circle.needs, needID) ?? {},
  );
  assert.equal(needParentConflicts.length, 2);
  assert.equal(circle.needs[needID]?.presence.state, "removed");

  // This mirrors SharedPlanDocument.createNeed's reactivation branch: it
  // mutates the visible removed need without counting competing need parents.
  const reactivateBeforePull = changeNeedCreateLikeSwift(
    deletedB,
    actorB.actorID,
    actorB.userPublicID,
    uuid(8_255),
    9_001,
    needID,
    "同じ品物",
    1,
    1_900_001_005,
  );
  const staleAccepted = await validatePlanMutation(
    acceptedBoth,
    Automerge.merge(
      Automerge.clone(acceptedBoth, { actor: actorB.actorID }),
      reactivateBeforePull,
    ),
    context(actorB),
  );
  assert.equal(staleAccepted.operations.length, 1);

  const reactivateAfterPull = changeNeedCreateLikeSwift(
    acceptedBoth,
    actorB.actorID,
    actorB.userPublicID,
    uuid(8_256),
    9_001,
    needID,
    "同じ品物",
    1,
    1_900_001_006,
  );
  const postPullChange = Automerge.decodeChange(
    Automerge.getLastLocalChange(reactivateAfterPull)!,
  );
  let rejection: Record<string, unknown> | null = null;
  try {
    await validatePlanMutation(
      acceptedBoth,
      reactivateAfterPull,
      context(actorB),
    );
  } catch (error) {
    if (!(error instanceof PlanDocumentError)) throw error;
    rejection = { code: error.code, details: error.details };
  }
  assert.deepEqual(rejection, {
    code: "invalid_plan_operation",
    details: {
      reason: "exact_change_proof",
      recovery: "export_and_rebuild_local_copy",
      localChangesPreserved: true,
      supportCode: "SP-OP-302",
    },
  });

  console.log(
    JSON.stringify(
      {
        result: "reproduced",
        scenario,
        parentCandidates: needParentConflicts.length,
        visiblePresence: circle.needs[needID]?.presence.state,
        reactivateBeforePeerPull: {
          result: "accepted",
          operations: staleAccepted.operations.length,
          dependencies: Automerge.decodeChange(
            Automerge.getLastLocalChange(reactivateBeforePull)!,
          ).deps,
        },
        reactivateAfterPeerPull: {
          result: "rejected",
          dependencies: postPullChange.deps,
          rejection,
        },
      },
      null,
      2,
    ),
  );
}

async function reproduceStaleMultiheadDependencyMismatch(): Promise<void> {
  const scenarioActors = Array.from({ length: 4 }, (_, index) => ({
    actorID: (index + 10).toString(16).repeat(32),
    userPublicID: (index + 1).toString(16).repeat(32),
    replicaID: uuid(8_301 + index),
  }));
  const actors = new Map<string, PlanActorAuthority>(
    scenarioActors.map((actor, index) => [
      actor.actorID,
      {
        ...actor,
        userID: index + 1,
        authVersion: 1,
        membershipEpoch: 1,
      },
    ]),
  );
  const activeMemberPublicIDs = new Set(
    scenarioActors.map((actor) => actor.userPublicID),
  );
  const context = (
    actor: (typeof scenarioActors)[number],
  ): PlanMutationValidationContext => ({
    planID,
    comiketNo,
    frameActorID: actor.actorID,
    frameUserPublicID: actor.userPublicID,
    actors,
    activeMemberPublicIDs,
    membershipEpoch: 1,
  });
  const [actorA, actorB, actorC, actorD] = scenarioActors as [
    (typeof scenarioActors)[number],
    (typeof scenarioActors)[number],
    (typeof scenarioActors)[number],
    (typeof scenarioActors)[number],
  ];

  const bootstrap = loadBootstrap(actorA.actorID);
  const circleCandidate = changeAs(
    bootstrap,
    actorA.actorID,
    uuid(8_310),
    circlePresence(actorA.userPublicID, 9_001, "active"),
    1_900_002_001,
  );
  const base = (
    await validatePlanMutation(bootstrap, circleCandidate, context(actorA))
  ).document;
  const left = changeAs(
    base,
    actorC.actorID,
    uuid(8_311),
    communicationOperation(actorC.userPublicID, 9_001, "left", true),
    1_900_002_002,
  );
  const right = changeAs(
    base,
    actorB.actorID,
    uuid(8_312),
    communicationOperation(actorB.userPublicID, 9_001, "right", true),
    1_900_002_003,
  );
  const acceptedLeft = (
    await validatePlanMutation(base, left, context(actorC))
  ).document;
  const multihead = (
    await validatePlanMutation(
      acceptedLeft,
      Automerge.merge(
        Automerge.clone(acceptedLeft, { actor: actorB.actorID }),
        right,
      ),
      context(actorB),
    )
  ).document;
  assert.equal(sortedHeads(multihead).length, 2);

  const clientChange = changeAs(
    multihead,
    actorC.actorID,
    uuid(8_313),
    communicationOperation(actorC.userPublicID, 9_001, "client", true),
    1_900_002_004,
  );
  const serverChange = changeAs(
    multihead,
    actorD.actorID,
    uuid(8_314),
    communicationOperation(actorD.userPublicID, 9_001, "server", true),
    1_900_002_005,
  );
  const advancedServer = (
    await validatePlanMutation(multihead, serverChange, context(actorD))
  ).document;
  const candidate = Automerge.merge(
    Automerge.clone(advancedServer, { actor: actorC.actorID }),
    clientChange,
  );
  const actual = Automerge.decodeChange(
    Automerge.getLastLocalChange(clientChange)!,
  );
  const before = Automerge.view(candidate, actual.deps);
  const clonedBefore = Automerge.clone(before, { actor: "f".repeat(256) });
  let rejection: Record<string, unknown> | null = null;
  try {
    await validatePlanMutation(advancedServer, candidate, context(actorC));
  } catch (error) {
    if (!(error instanceof PlanDocumentError)) throw error;
    rejection = { code: error.code, details: error.details };
  }
  assert.deepEqual(rejection, {
    code: "invalid_plan_operation",
    details: {
      reason: "exact_change_proof",
      recovery: "export_and_rebuild_local_copy",
      localChangesPreserved: true,
      supportCode: "SP-OP-302",
    },
  });

  console.log(
    JSON.stringify(
      {
        result: "reproduced",
        scenario,
        clientDependencies: actual.deps.slice().sort(),
        historicalViewHeads: sortedHeads(before),
        clonedHistoricalViewHeads: sortedHeads(clonedBefore),
        serverHeadsBeforeClientFrame: sortedHeads(advancedServer),
        rejection,
      },
      null,
      2,
    ),
  );
}

function changeAs(
  document: Automerge.Doc<PlanDocument>,
  actorID: string,
  operationID: string,
  operation: PlanOperation,
  timestamp: number,
): Automerge.Doc<PlanDocument> {
  return Automerge.change(
    Automerge.clone(document, { actor: actorID }),
    { message: `operation:${operationID}`, time: timestamp },
    (draft) => applyPlanOperation(draft, operationID, operation),
  );
}

function changeCirclePresenceLikeSwift(
  document: Automerge.Doc<PlanDocument>,
  actorID: string,
  actorUserID: string,
  operationID: string,
  wcID: number,
  state: "active" | "removed",
  timestamp: number,
): Automerge.Doc<PlanDocument> {
  const operation = circlePresence(actorUserID, wcID, state);
  return Automerge.change(
    Automerge.clone(document, { actor: actorID }),
    { message: `operation:${operationID}`, time: timestamp },
    (draft) => {
      const circle = draft.circles[String(wcID)];
      if (!circle) throw new Error(`missing visible circle ${wcID}`);
      circle.presence = { state, operationID };
      draft.operations[operationID] = operation;
    },
  );
}

function changeNeedCreateLikeSwift(
  document: Automerge.Doc<PlanDocument>,
  actorID: string,
  actorUserID: string,
  operationID: string,
  wcID: number,
  needID: string,
  itemName: string,
  wantedQuantity: number,
  timestamp: number,
): Automerge.Doc<PlanDocument> {
  const operation = createNeed(
    actorUserID,
    wcID,
    needID,
    itemName,
    wantedQuantity,
  );
  return Automerge.change(
    Automerge.clone(document, { actor: actorID }),
    { message: `operation:${operationID}`, time: timestamp },
    (draft) => {
      const need = draft.circles[String(wcID)]?.needs[needID];
      if (!need) throw new Error(`missing visible need ${needID}`);
      need.presence = { state: "active", operationID };
      need.requesterUserID = actorUserID;
      need.itemName = itemName;
      need.unitPrice = null;
      need.wantedQuantity = new Automerge.Int(wantedQuantity);
      draft.operations[operationID] = operation;
    },
  );
}

function loadBootstrap(actorID: string): Automerge.Doc<PlanDocument> {
  const fixture = JSON.parse(
    readFileSync(
      resolve(serverDirectory, "tests/fixtures/automerge-bootstrap-v1.json"),
      "utf8",
    ),
  ) as { document: string };
  return Automerge.clone(
    Automerge.load<PlanDocument>(Buffer.from(fixture.document, "base64url")),
    { actor: actorID },
  );
}

function circlePresence(
  actorUserID: string,
  wcID: number,
  state: "active" | "removed",
): PlanOperation {
  return {
    type: "shared_plan.circle.presence.v1",
    actorUserID,
    payload: { v: 1, wcID, state },
  };
}

function createNeed(
  actorUserID: string,
  wcID: number,
  needID: string,
  itemName: string,
  wantedQuantity: number,
): PlanOperation {
  return {
    type: "shared_plan.need.create.v1",
    actorUserID,
    payload: {
      v: 1,
      wcID,
      needID,
      requesterUserID: actorUserID,
      itemName,
      unitPrice: null,
      wantedQuantity,
    },
  };
}

function communicationOperation(
  actorUserID: string,
  wcID: number,
  key: string,
  value: boolean,
): PlanOperation {
  return {
    type: "shared_plan.circle.communication.set.v1",
    actorUserID,
    payload: { v: 1, wcID, key, value },
  };
}

function differentQuantity(random: () => number, current: number): number {
  const candidate = randomInteger(random, 6);
  return candidate === current ? (candidate + 1) % 6 : candidate;
}

function sortedHeads(document: Automerge.Doc<PlanDocument>): string[] {
  return Automerge.getHeads(document).slice().sort();
}

function parentConflictSummary(
  document: Automerge.Doc<PlanDocument>,
): Array<Record<string, unknown>> {
  const result: Array<Record<string, unknown>> = [];
  for (const [circleKey, visibleCircle] of Object.entries(document.circles)) {
    const circleCandidates = Object.keys(
      Automerge.getConflicts(document.circles, circleKey) ?? {},
    );
    if (circleCandidates.length > 1) {
      result.push({ path: ["circles", circleKey], candidates: circleCandidates });
    }
    if (!visibleCircle) continue;
    for (const needID of Object.keys(visibleCircle.needs)) {
      const needCandidates = Object.keys(
        Automerge.getConflicts(visibleCircle.needs, needID) ?? {},
      );
      if (needCandidates.length > 1) {
        result.push({
          path: ["circles", circleKey, "needs", needID],
          candidates: needCandidates,
        });
      }
    }
  }
  return result;
}

async function conflictBlocksOrdinaryClientOperation(
  document: Automerge.Doc<PlanDocument>,
  operation: PlanOperation,
): Promise<boolean> {
  const wcID = String(operation.payload.wcID);
  const needID =
    "needID" in operation.payload ? String(operation.payload.needID) : null;
  const parentConflicts = parentConflictSummary(document);
  if (
    parentConflicts.some(
      (conflict) =>
        canonicalJSON(conflict.path) ===
        canonicalJSON(["circles", wcID]),
    )
  ) {
    return true;
  }
  if (
    needID !== null &&
    parentConflicts.some(
      (conflict) =>
        canonicalJSON(conflict.path) ===
        canonicalJSON(["circles", wcID, "needs", needID]),
    )
  ) {
    return true;
  }

  if (
    operation.type !== "shared_plan.circle.presence.v1" &&
    operation.type !== "shared_plan.need.create.v1" &&
    operation.type !== "shared_plan.need.delete.v1"
  ) {
    return false;
  }
  const targetPath =
    operation.type === "shared_plan.circle.presence.v1"
      ? ["circles", wcID, "presence"]
      : ["circles", wcID, "needs", needID!, "presence"];
  return (await detectPlanConflicts(document)).some(
    (conflict) =>
      canonicalJSON(conflict.path) === canonicalJSON(targetPath),
  );
}

function compareExactReplay(
  before: Automerge.Doc<PlanDocument>,
  actualChange: ReturnType<typeof Automerge.decodeChange>,
  operationID: string,
  operation: PlanOperation,
): Record<string, unknown> {
  try {
    const clonedBefore = Automerge.clone(before, { actor: "f".repeat(256) });
    const expected = Automerge.change(
      clonedBefore,
      (draft) => applyPlanOperation(draft, operationID, operation),
    );
    const expectedBytes = Automerge.getLastLocalChange(expected);
    if (!expectedBytes) return { replayError: "no expected change" };
    const actual = canonicalChangeOps(actualChange);
    const reconstructed = canonicalChangeOps(
      Automerge.decodeChange(expectedBytes),
    );
    const actualJSON = canonicalJSON(actual.operations);
    const expectedJSON = canonicalJSON(reconstructed.operations);
    const actualDependencies = actualChange.deps.slice().sort();
    const expectedDependencies = Automerge.decodeChange(expectedBytes).deps
      .slice()
      .sort();
    if (
      actualJSON === expectedJSON &&
      canonicalJSON(actualDependencies) === canonicalJSON(expectedDependencies)
    ) {
      return { matches: true };
    }
    if (actualJSON === expectedJSON) {
      return {
        matches: false,
        reason: "dependencies differ",
        actualDependencies,
        expectedDependencies,
        beforeHeads: sortedHeads(before),
        clonedBeforeHeads: sortedHeads(clonedBefore),
        savedBeforeHeads: sortedHeads(
          Automerge.load<PlanDocument>(Automerge.save(before)),
        ),
      };
    }
    const maximum = Math.max(actual.operations.length, reconstructed.operations.length);
    for (let index = 0; index < maximum; index += 1) {
      if (
        canonicalJSON(actual.operations[index]) !==
        canonicalJSON(reconstructed.operations[index])
      ) {
        return {
          matches: false,
          actualOperationCount: actual.operations.length,
          expectedOperationCount: reconstructed.operations.length,
          firstDifferenceIndex: index,
          actual: actual.operations[index],
          expected: reconstructed.operations[index],
        };
      }
    }
    return { matches: false, reason: "encoded canonical arrays differ" };
  } catch (error) {
    return {
      replayError:
        error instanceof PlanDocumentError
          ? { code: error.code, details: error.details }
          : error instanceof Error
            ? error.message
            : String(error),
    };
  }
}

function canonicalChangeOps(
  change: ReturnType<typeof Automerge.decodeChange>,
): { operations: Array<Record<string, unknown>> } {
  const localIDs = new Set<string>();
  for (let index = 0; index < change.ops.length; index += 1) {
    localIDs.add(`${change.startOp + index}@${change.actor}`);
  }
  const operationsByID = new Map(
    change.ops.map((operation, index) => [
      `${change.startOp + index}@${change.actor}`,
      operation as unknown as Record<string, unknown>,
    ]),
  );
  const canonicalIDs = new Map<string, string>();
  const canonical: Array<Record<string, unknown>> = [];
  let nextCanonicalID = 0;

  const reference = (value: string): string => {
    if (!localIDs.has(value)) return value;
    const canonicalID = canonicalIDs.get(value);
    if (!canonicalID) throw new Error(`unresolved local operation ${value}`);
    return canonicalID;
  };
  const localReferences = (operation: Record<string, unknown>): string[] => {
    const result: string[] = [];
    for (const key of ["obj", "key", "elemId"] as const) {
      const value = operation[key];
      if (typeof value === "string" && localIDs.has(value)) result.push(value);
    }
    if (Array.isArray(operation.pred)) {
      for (const value of operation.pred) {
        const item = String(value);
        if (localIDs.has(item)) result.push(item);
      }
    }
    return result;
  };
  const indegree = new Map<string, number>();
  const dependents = new Map<string, string[]>();
  for (const [operationID, operation] of operationsByID) {
    const dependencies = new Set(localReferences(operation));
    indegree.set(operationID, dependencies.size);
    for (const dependency of dependencies) {
      const items = dependents.get(dependency) ?? [];
      items.push(operationID);
      dependents.set(dependency, items);
    }
  }
  const normalized = (
    operation: Record<string, unknown>,
  ): Record<string, unknown> =>
    Object.fromEntries(
      Object.entries(operation)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, value]) => {
          if (
            (key === "obj" || key === "key" || key === "elemId") &&
            typeof value === "string"
          ) {
            return [key, reference(value)];
          }
          if (key === "pred" && Array.isArray(value)) {
            return [
              key,
              value
                .map((item) => reference(String(item)))
                .sort((left, right) => left.localeCompare(right)),
            ];
          }
          return [key, value];
        }),
    );

  let readyOperationIDs = Array.from(indegree)
    .filter(([, count]) => count === 0)
    .map(([operationID]) => operationID);
  let processed = 0;
  while (readyOperationIDs.length > 0) {
    const ready = readyOperationIDs.map((operationID) => ({
      operationID,
      operation: normalized(operationsByID.get(operationID)!),
    }));
    ready.sort((left, right) =>
      canonicalJSON(left.operation).localeCompare(canonicalJSON(right.operation)),
    );
    let previous: string | null = null;
    for (const item of ready) {
      const encoded = canonicalJSON(item.operation);
      if (encoded === previous) throw new Error("ambiguous canonical operations");
      previous = encoded;
      canonicalIDs.set(item.operationID, `#${nextCanonicalID++}`);
      canonical.push(item.operation);
      processed += 1;
    }
    const nextReady: string[] = [];
    for (const item of ready) {
      for (const dependent of dependents.get(item.operationID) ?? []) {
        const next = (indegree.get(dependent) ?? 0) - 1;
        indegree.set(dependent, next);
        if (next === 0) nextReady.push(dependent);
      }
    }
    readyOperationIDs = nextReady;
  }
  if (processed !== operationsByID.size) throw new Error("cyclic change operations");
  return {
    operations: canonical.sort((left, right) =>
      canonicalJSON(left).localeCompare(canonicalJSON(right)),
    ),
  };
}

function uuid(value: number): string {
  return `00000000-0000-4000-8000-${value.toString(16).padStart(12, "0")}`;
}

function choose<T>(random: () => number, values: readonly T[]): T | undefined {
  return values[randomInteger(random, values.length)];
}

function randomInteger(random: () => number, upperBound: number): number {
  return Math.floor(random() * upperBound);
}

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function integerArgument(name: string, fallback: number): number {
  const prefix = `--${name}=`;
  const value = process.argv.find((argument) => argument.startsWith(prefix));
  if (!value) return fallback;
  const parsed = Number.parseInt(value.slice(prefix.length), 10);
  if (!Number.isSafeInteger(parsed)) throw new Error(`invalid ${prefix} value`);
  return parsed;
}

function stringArgument(name: string, fallback: string): string {
  const prefix = `--${name}=`;
  const value = process.argv.find((argument) => argument.startsWith(prefix));
  return value ? value.slice(prefix.length) : fallback;
}

function addCounters(target: Counters, source: Counters): void {
  for (const key of Object.keys(target) as Array<keyof Counters>) {
    target[key] += source[key];
  }
}
