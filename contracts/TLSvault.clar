;; Time-Locked STX Vault Contract
;; Allows users to lock STX tokens for a specified period

;; Data map to store lock information for each user
(define-map locks principal { amount: uint, unlock-height: uint })

;; Get the contract principal (helper function)
(define-private (get-contract-principal)
  (as-contract tx-sender))

;; Lock STX tokens for a specified period
;; @param amount: Amount of STX to lock (in microSTX)
;; @param period: Number of blocks to lock the STX
(define-public (lock (amount uint) (period uint))
  (let ((sender-balance (stx-get-balance tx-sender))
        (contract-principal (get-contract-principal))
        (contract-balance-before (stx-get-balance contract-principal)))
    (begin
      ;; Ensure amount is greater than 0
      (asserts! (> amount u0) (err u102))
      ;; Ensure period is greater than 0
      (asserts! (> period u0) (err u103))
      ;; Ensure user doesn't already have an active lock
      (asserts! (is-none (map-get? locks tx-sender)) (err u104))
      ;; Verify sender has sufficient STX balance
      (asserts! (>= sender-balance amount) (err u105))
      ;; Transfer STX from caller to contract
      (try! (stx-transfer? amount tx-sender contract-principal))
      ;; Verify the contract received the STX
      (asserts! (is-eq (stx-get-balance contract-principal) 
                       (+ contract-balance-before amount)) (err u106))
      ;; Store lock information
      (map-set locks tx-sender { 
        amount: amount, 
        unlock-height: (+ stacks-block-height period) 
      })
      (ok true))))

;; Withdraw locked STX tokens after the lock period expires
(define-public (withdraw)
  (let ((lock-data (map-get? locks tx-sender)))
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
              ;; Remove the lock entry
              (map-delete locks tx-sender)
              ;; Transfer STX from contract back to user
              (try! (as-contract (stx-transfer? amt tx-sender tx-sender)))
              (ok amt))
            ;; Lock period hasn't expired yet
            (err u100)))
      ;; No lock found for this user
      (err u101))))

;; Read-only function to get lock information for a user
;; @param user: Principal to check lock information for
(define-read-only (get-lock-info (user principal))
  (map-get? locks user))

;; Read-only function to check if a lock can be withdrawn
;; @param user: Principal to check
(define-read-only (can-withdraw (user principal))
  (match (map-get? locks user)
    lock-info (>= stacks-block-height (get unlock-height lock-info))
    false))

;; Read-only function to get contract's total STX balance
(define-read-only (get-contract-balance)
  (stx-get-balance (get-contract-principal)))

;; Error codes:
;; u100: Lock period hasn't expired yet
;; u101: No lock found for this user
;; u102: Invalid amount (must be > 0)
;; u103: Invalid period (must be > 0)
;; u104: User already has an active lock
;; u105: Insufficient STX balance
;; u106: Contract didn't receive expected STX amount
;; u107: Contract has insufficient balance for withdrawal