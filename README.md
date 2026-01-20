# TLSvault

Time-Locked STX Vault (Clarity)

This repository contains a simple Clarity smart contract, `contracts/TLSvault.clar`, which implements a per-user time-locked STX vault. Users can lock STX for a specified number of blocks and withdraw the full amount after the lock period expires.

## Features

- Single active lock per principal (user)
- Lock STX for a number of blocks
- Withdraw after unlock height is reached
- Read-only helpers to inspect locks and contract balance

## Contract API

All amounts are in microSTX (uint).

Public functions:

- `(lock amount period)`
  - Locks `amount` microSTX from the caller for `period` blocks.
  - Returns `(ok true)` on success.
  - Errors:
    - `u102` - Invalid amount (must be > 0)
    - `u103` - Invalid period (must be > 0)
    - `u104` - User already has an active lock
    - `u105` - Insufficient STX balance
    - `u106` - Contract didn't receive expected STX amount

- `(withdraw)`
  - Withdraws the caller's locked STX after the lock expires.
  - Returns `(ok amt)` with the withdrawn amount on success.
  - Errors:
    - `u100` - Lock period hasn't expired yet
    - `u101` - No lock found for this user
    - `u107` - Contract has insufficient balance for withdrawal

Read-only functions:

- `(get-lock-info user)` — returns optional lock info `{ amount, unlock-height }` for `user`.
- `(can-withdraw user)` — returns `true` if `stacks-block-height >= unlock-height` for `user`'s lock.
- `(get-contract-balance)` — returns the contract's current STX balance.

## Storage

- `locks` (map principal => { amount: uint, unlock-height: uint })

## Error codes

- `u100` — Lock period hasn't expired yet.
- `u101` — No lock found for this user.
- `u102` — Invalid amount (must be > 0).
- `u103` — Invalid period (must be > 0).
- `u104` — User already has an active lock.
- `u105` — Insufficient STX balance.
- `u106` — Contract didn't receive expected STX amount.
- `u107` — Contract has insufficient balance for withdrawal.

## Example usage (Clarinet / tests)

- To run contract checks (requires Clarinet):

```bash
clarinet check
```

- To run the TypeScript tests in this repo (if set up):

```bash
npm install
npm test
```

## Notes & Recommendations

- The contract allows only one active lock per principal. If you need multiple concurrent locks, modify storage to support IDs or lists.
- Consider adding event emissions (or off-chain indexing) to track locks and withdrawals.
- The contract uses a simple `unlock-height = stacks-block-height + period` computation; take care with very large `period` values.
- Audit transfer and balance-check logic before deploying to mainnet. Ensure `as-contract` and `stx-transfer?` calls use the correct principals.

## License

This repository is unlicensed; add a LICENSE file if you want to apply an open-source license.
