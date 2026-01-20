import { describe, expect, it } from "vitest";
import stacks from "@stacks/transactions";
import type { ClarityValue } from "@stacks/transactions";

const { ClarityType, cvToJSON, cvToValue, standardPrincipalCV, uintCV } = stacks;

const contractName = "TLSvault";
const accounts = simnet.getAccounts();
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;

const principal = standardPrincipalCV;

const readLockTuple = (cv: ClarityValue) => {
  const value = (cvToValue(cv) as any).value as Record<string, any>;
  return {
    amount: BigInt(value.amount.value),
    unlockHeight: BigInt(value["unlock-height"].value),
    createdAt: BigInt(value["created-at"].value),
  };
};

const lock = (sender: string, amount: bigint, period: bigint) =>
  simnet.callPublicFn(
    contractName,
    "lock",
    [uintCV(amount), uintCV(period)],
    sender,
  );

const withdraw = (sender: string, lockId: bigint) =>
  simnet.callPublicFn(
    contractName,
    "withdraw",
    [uintCV(lockId)],
    sender,
  );

const withdrawRange = (
  sender: string,
  start: bigint,
  end: bigint,
) =>
  simnet.callPublicFn(
    contractName,
    "withdraw-eligible-range",
    [uintCV(start), uintCV(end)],
    sender,
  );

const lockExists = (user: string, lockId: bigint, caller = user) =>
  simnet.callReadOnlyFn(
    contractName,
    "lock-exists",
    [principal(user), uintCV(lockId)],
    caller,
  );

const lockInfo = (user: string, lockId: bigint, caller = user) =>
  simnet.callReadOnlyFn(
    contractName,
    "get-lock-info",
    [principal(user), uintCV(lockId)],
    caller,
  );

const lockCount = (user: string, caller = user) =>
  simnet.callReadOnlyFn(
    contractName,
    "get-user-lock-count",
    [principal(user)],
    caller,
  );

const totalLockedRange = (
  user: string,
  start: bigint,
  end: bigint,
  caller = user,
) =>
  simnet.callReadOnlyFn(
    contractName,
    "get-total-locked-range",
    [principal(user), uintCV(start), uintCV(end)],
    caller,
  );

const totalLocked = (user: string, caller = user) =>
  simnet.callReadOnlyFn(contractName, "get-total-locked", [principal(user)], caller);

const contractBalance = (caller = wallet1) => {
  const balance = simnet.callReadOnlyFn(
    contractName,
    "get-contract-balance",
    [],
    caller,
  ).result;
  const json = cvToJSON(balance) as any;
  const value = json?.value;
  if (typeof value === "object" && value !== null && "value" in value) {
    return BigInt(value.value);
  }
  return BigInt(value ?? 0);
};

describe("TLSvault core flows", () => {
  it("locks STX with sequential IDs and records metadata", () => {
    const beforeBalance = contractBalance();
    const amount1 = 1_000_000n;
    const period1 = 5n;

    const lock1 = lock(wallet1, amount1, period1);
    expect(lock1.result).toBeOk(uintCV(1n));

    const count1 = lockCount(wallet1).result;
    expect(count1).toBeUint(1n);

    const info1Result = lockInfo(wallet1, 1n).result;
    expect(info1Result).toHaveClarityType(ClarityType.OptionalSome);
    const info1 = readLockTuple(info1Result);
    expect(info1.amount).toBe(amount1);
    expect(info1.unlockHeight - info1.createdAt).toBe(period1);

    const afterFirstLockBalance = contractBalance();
    expect(afterFirstLockBalance - beforeBalance).toBe(amount1);

    const lock2 = lock(wallet1, 2_000_000n, 7n);
    expect(lock2.result).toBeOk(uintCV(2n));
    const count2 = lockCount(wallet1).result;
    expect(count2).toBeUint(2n);
  });

  it("rejects withdrawal before unlock height", () => {
    lock(wallet1, 500_000n, 3n);

    const withdrawEarly = withdraw(wallet1, 1n);
    expect(withdrawEarly.result).toBeErr(uintCV(100n));

    const exists = lockExists(wallet1, 1n).result;
    expect(exists).toBeBool(true);
  });

  it("withdraws after maturity and clears lock state", () => {
    const amount = 750_000n;
    const period = 2n;

    const startingBalance = contractBalance();
    const { result: lockResult } = lock(wallet1, amount, period);
    expect(lockResult).toBeOk(uintCV(1n));

    const afterLockBalance = contractBalance();
    expect(afterLockBalance - startingBalance).toBe(amount);

    simnet.mineEmptyStacksBlocks(Number(period));

    const withdrawResult = withdraw(wallet1, 1n).result;
    expect(withdrawResult).toBeOk(uintCV(amount));

    const afterWithdrawBalance = contractBalance();
    expect(afterWithdrawBalance).toBe(startingBalance);

    const exists = lockExists(wallet1, 1n).result;
    expect(exists).toBeBool(false);
  });

  it("batch-withdraws only eligible locks within range", () => {
    lock(wallet1, 100_000n, 1n); // id 1
    lock(wallet1, 200_000n, 2n); // id 2
    lock(wallet1, 300_000n, 6n); // id 3

    simnet.mineEmptyStacksBlocks(3); // first two mature

    const batch = withdrawRange(wallet1, 1n, 3n).result;
    expect(batch).toBeOk(uintCV(300_000n));

    expect(lockExists(wallet1, 1n).result).toBeBool(false);
    expect(lockExists(wallet1, 2n).result).toBeBool(false);
    expect(lockExists(wallet1, 3n).result).toBeBool(true);

    const secondBatch = withdrawRange(wallet1, 1n, 3n).result;
    expect(secondBatch).toBeErr(uintCV(108n));
  });

  it("validates withdraw range boundaries", () => {
    lock(wallet2, 50_000n, 1n);

    const invalidStart = withdrawRange(wallet2, 0n, 1n).result;
    expect(invalidStart).toBeErr(uintCV(109n));

    const invalidSpan = withdrawRange(wallet2, 2n, 1n).result;
    expect(invalidSpan).toBeErr(uintCV(110n));
  });

  it("reports locked totals with range capping and defaults", () => {
    lock(wallet1, 10_000n, 10n); // id 1
    lock(wallet1, 20_000n, 10n); // id 2
    lock(wallet1, 30_000n, 10n); // id 3

    const totalAll = totalLockedRange(wallet1, 1n, 3n).result;
    expect(totalAll).toBeUint(60_000n);

    const cappedEnd = totalLockedRange(wallet1, 2n, 50n).result;
    expect(cappedEnd).toBeUint(50_000n);

    const defaultWindow = totalLocked(wallet1).result;
    expect(defaultWindow).toBeUint(60_000n);

    const reversed = totalLockedRange(wallet1, 4n, 2n).result;
    expect(reversed).toBeUint(0n);
  });
});
