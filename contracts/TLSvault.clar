;; Time-Locked STX Vault Contract - Enhanced Version
;; Allows users to create multiple locks with unique IDs and range-based batch operations

;; Data structures
(define-map locks { user: principal, lock-id: uint } { amount: uint, unlock-height: uint, created-at: uint })
(define-map user-lock-counter principal uint)

;; Constants
(define-constant MAX-BATCH-RANGE u50) ;; Maximum number of locks processed per batch operation
(define-constant BATCH-OFFSETS
  (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9
        u10 u11 u12 u13 u14 u15 u16 u17 u18 u19
        u20 u21 u22 u23 u24 u25 u26 u27 u28 u29
        u30 u31 u32 u33 u34 u35 u36 u37 u38 u39
        u40 u41 u42 u43 u44 u45 u46 u47 u48 u49))

;; Helper function to get minimum of two uint values
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b))

;; Helper to cap a range end based on a maximum window and the user's highest lock id
(define-private (bounded-range-end (start-id uint) (limit uint) (user-max uint))
  (let ((limit-adjusted (if (> limit u0) (- limit u1) u0)))
    (let ((candidate (+ start-id limit-adjusted)))
      (if (> candidate user-max)
          user-max
          candidate))))

;; Get the contract principal (helper function)
(define-private (get-contract-principal)
  (as-contract tx-sender))

;; Read-only function to get all lock IDs for a user (up to their counter)
(define-read-only (get-user-lock-count (user principal))
  (default-to u0 (map-get? user-lock-counter user)))

;; Get next lock ID for a user
(define-private (get-next-lock-id (user principal))
  (let ((current-counter (get-user-lock-count user)))
    (+ current-counter u1)))

;; Lock STX tokens for a specified period with unique lock ID
;; @param amount: Amount of STX to lock (in microSTX)
;; @param period: Number of blocks to lock the STX
(define-public (lock (amount uint) (period uint))
  (let ((sender-balance (stx-get-balance tx-sender))
        (contract-principal (get-contract-principal))
        (contract-balance-before (stx-get-balance contract-principal))
        (lock-id (get-next-lock-id tx-sender)))
    (begin
      ;; Ensure amount is greater than 0
      (asserts! (> amount u0) (err u102))
      ;; Ensure period is greater than 0
      (asserts! (> period u0) (err u103))
      ;; Verify sender has sufficient STX balance
      (asserts! (>= sender-balance amount) (err u105))
      ;; Transfer STX from caller to contract
      (try! (stx-transfer? amount tx-sender contract-principal))
      ;; Verify the contract received the STX
      (asserts! (is-eq (stx-get-balance contract-principal) 
                       (+ contract-balance-before amount)) (err u106))
      ;; Store lock information with unique ID
      (map-set locks { user: tx-sender, lock-id: lock-id } { 
        amount: amount, 
        unlock-height: (+ stacks-block-height period),
        created-at: stacks-block-height
      })
      ;; Update user's lock counter
      (map-set user-lock-counter tx-sender lock-id)
      (ok lock-id))))

;; Withdraw specific locked STX tokens by lock ID
;; @param lock-id: The ID of the lock to withdraw
(define-public (withdraw (lock-id uint))
  (let ((lock-key { user: tx-sender, lock-id: lock-id })
        (lock-data (map-get? locks lock-key)))
    (match lock-data
      lock-info
        (let ((amt (get amount lock-info)) 
              (unlock-height (get unlock-height lock-info))
              (contract-principal (get-contract-principal))
              (contract-balance (stx-get-balance contract-principal)))
          ;; Check if the lock period has expired
          (if (>= stacks-block-height unlock-height)
            (begin
              ;; Verify contract has sufficient balance for withdrawal
              (asserts! (>= contract-balance amt) (err u107))
              ;; Remove the lock entry first (prevents reentrancy)
              (map-delete locks lock-key)
              ;; Transfer STX from contract back to user
              (try! (as-contract (stx-transfer? amt contract-principal tx-sender)))
              (ok amt))
            ;; Lock period hasn't expired yet
            (err u100)))
      ;; No lock found for this user and lock ID
      (err u101))))

;; Backward compatibility: withdraw function without lock-id (withdraws first available lock)
(define-public (withdraw-legacy)
  (let ((user-counter (get-user-lock-count tx-sender)))
    (if (> user-counter u0)
      (withdraw u1)
      (err u101))))

;; Helper used by folds to process withdrawals for a specific offset
(define-private (process-withdraw-offset
  (offset uint)
  (state (tuple (start uint) (end uint) (total uint))))
  (let ((current-id (+ (get start state) offset)))
    (if (> current-id (get end state))
        state
        (match (withdraw current-id)
          amount (merge state { total: (+ (get total state) amount) })
          error state))))

;; Batch withdraw eligible locks using a caller-defined range (bounded by MAX-BATCH-RANGE)
;; @param start-id: First lock ID to evaluate
;; @param end-id: Last lock ID to evaluate (inclusive)
(define-public (withdraw-eligible-range (start-id uint) (end-id uint))
  (begin
    (asserts! (>= start-id u1) (err u109))
    (asserts! (<= start-id end-id) (err u110))
    (let ((user-counter (get-user-lock-count tx-sender)))
      (if (or (is-eq user-counter u0) (> start-id user-counter))
          (err u108)
          (let ((max-end (bounded-range-end start-id MAX-BATCH-RANGE user-counter)))
            (let ((actual-end (min-uint end-id max-end)))
              (let ((result-state
                      (fold process-withdraw-offset
                            BATCH-OFFSETS
                            { start: start-id, end: actual-end, total: u0 })))
                (if (> (get total result-state) u0)
                    (ok (get total result-state))
                    (err u108)))))))))

;; Batch withdraw eligible locks (defaults to the first MAX-BATCH-RANGE IDs)
(define-public (withdraw-all-eligible)
  (let ((user-counter (get-user-lock-count tx-sender)))
    (if (is-eq user-counter u0)
        (err u108)
        (let ((default-end (bounded-range-end u1 MAX-BATCH-RANGE user-counter)))
          (withdraw-eligible-range u1 default-end)))))

;; Read-only function to get lock information for a specific lock
;; @param user: Principal to check
;; @param lock-id: Lock ID to check
(define-read-only (get-lock-info (user principal) (lock-id uint))
  (map-get? locks { user: user, lock-id: lock-id }))

;; Backward compatibility: get lock info for first lock
(define-read-only (get-lock-info-legacy (user principal))
  (map-get? locks { user: user, lock-id: u1 }))

;; Read-only function to check if a specific lock can be withdrawn
;; @param user: Principal to check
;; @param lock-id: Lock ID to check
(define-read-only (can-withdraw (user principal) (lock-id uint))
  (match (map-get? locks { user: user, lock-id: lock-id })
    lock-info (>= stacks-block-height (get unlock-height lock-info))
    false))

;; Backward compatibility: check if first lock can be withdrawn
(define-read-only (can-withdraw-legacy (user principal))
  (can-withdraw user u1))

;; Read-only function to get contract's total STX balance
(define-read-only (get-contract-balance)
  (stx-get-balance (get-contract-principal)))

;; Helper used by folds to sum balances across offsets
(define-private (process-sum-offset
  (offset uint)
  (state (tuple (user principal) (start uint) (end uint) (total uint))))
  (let ((current-id (+ (get start state) offset)))
    (if (> current-id (get end state))
        state
        (match (get-lock-info (get user state) current-id)
          lock-info (merge state { total: (+ (get total state) (get amount lock-info)) })
          state))))

;; Get total locked amount for a user within a caller-defined range (bounded by MAX-BATCH-RANGE)
(define-read-only (get-total-locked-range (user principal) (start-id uint) (end-id uint))
  (if (> start-id end-id)
      u0
      (let ((user-counter (get-user-lock-count user)))
        (if (or (is-eq user-counter u0) (> start-id user-counter))
            u0
            (let ((max-end (bounded-range-end start-id MAX-BATCH-RANGE user-counter)))
              (let ((actual-end (min-uint end-id max-end)))
                (let ((result-state
                        (fold process-sum-offset
                              BATCH-OFFSETS
                              { user: user, start: start-id, end: actual-end, total: u0 })))
                  (get total result-state))))))))

;; Get total locked amount for a user across their earliest locks (first MAX-BATCH-RANGE IDs)
(define-read-only (get-total-locked (user principal))
  (let ((user-counter (get-user-lock-count user)))
    (if (is-eq user-counter u0)
        u0
        (let ((default-end (bounded-range-end u1 MAX-BATCH-RANGE user-counter)))
          (let ((result-state
                  (fold process-sum-offset
                        BATCH-OFFSETS
                        { user: user, start: u1, end: default-end, total: u0 })))
            (get total result-state))))))

;; Emergency function to check if a lock exists
(define-read-only (lock-exists (user principal) (lock-id uint))
  (is-some (map-get? locks { user: user, lock-id: lock-id })))

;; Get lock creation timestamp
(define-read-only (get-lock-created-at (user principal) (lock-id uint))
  (match (map-get? locks { user: user, lock-id: lock-id })
    lock-info (some (get created-at lock-info))
    none))

;; Error codes:
;; u100: Lock period hasn't expired yet
;; u101: No lock found for this user/lock-id
;; u102: Invalid amount (must be > 0)
;; u103: Invalid period (must be > 0)
;; u105: Insufficient STX balance
;; u106: Contract didn't receive expected STX amount
;; u107: Contract has insufficient balance for withdrawal
;; u108: No eligible locks found for batch withdrawal
;; u109: Invalid lock ID (start must be >= 1)
;; u110: Invalid range (start must be <= end)
