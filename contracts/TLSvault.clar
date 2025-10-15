;; Time-Locked STX Vault Contract - Enhanced Version
;; Allows users to create multiple locks with unique IDs

;; Data structures
(define-map locks { user: principal, lock-id: uint } { amount: uint, unlock-height: uint, created-at: uint })
(define-map user-lock-counter principal uint)

;; Get the contract principal (helper function)
(define-private (get-contract-principal)
  (as-contract tx-sender))

;; Get next lock ID for a user
(define-private (get-next-lock-id (user principal))
  (let ((current-counter (default-to u0 (map-get? user-lock-counter user))))
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
              ;; FIXED: Transfer STX from contract back to user
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

;; Read-only function to get lock information for a specific lock
;; @param user: Principal to check
;; @param lock-id: Lock ID to check
(define-read-only (get-lock-info (user principal) (lock-id uint))
  (map-get? locks { user: user, lock-id: lock-id }))

;; Backward compatibility: get lock info for first lock
(define-read-only (get-lock-info-legacy (user principal))
  (map-get? locks { user: user, lock-id: u1 }))

;; Read-only function to get all lock IDs for a user (up to their counter)
;; @param user: Principal to check
(define-read-only (get-user-lock-count (user principal))
  (default-to u0 (map-get? user-lock-counter user)))

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

;; Helper function for batch operations
(define-private (try-withdraw-lock (lock-id uint) (total-withdrawn uint))
  (if (<= lock-id (get-user-lock-count tx-sender))
    (if (can-withdraw tx-sender lock-id)
      (match (withdraw lock-id)
        success (+ total-withdrawn success)
        error total-withdrawn)
      total-withdrawn)
    total-withdrawn))

;; Batch withdraw eligible locks (up to 10 locks for gas efficiency)
(define-public (withdraw-all-eligible)
  (let ((total-withdrawn 
         (fold try-withdraw-lock 
               (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10) 
               u0)))
    (if (> total-withdrawn u0)
      (ok total-withdrawn)
      (err u108))))

;; Get total locked amount for a user across all their locks
(define-read-only (get-total-locked (user principal))
  (let ((user-counter (get-user-lock-count user)))
    (fold sum-lock-amount (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10) u0)))

;; Helper function to sum lock amounts
(define-private (sum-lock-amount (lock-id uint) (total uint))
  (if (<= lock-id (get-user-lock-count tx-sender))
    (match (get-lock-info tx-sender lock-id)
      lock-info (+ total (get amount lock-info))
      total)
    total))

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
