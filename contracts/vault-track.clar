;; vault-track
;; A secure digital asset vault management system with comprehensive access controls
;; and advanced security features for the Stacks blockchain.

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-VAULT-NOT-FOUND (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-WITHDRAWAL-LIMIT-EXCEEDED (err u103))
(define-constant ERR-WITHDRAWAL-PENDING (err u104))
(define-constant ERR-PENDING-WITHDRAWAL-NOT-FOUND (err u105))
(define-constant ERR-COOLING-PERIOD-ACTIVE (err u106))
(define-constant ERR-DELEGATE-NOT-FOUND (err u107))
(define-constant ERR-DELEGATE-EXISTS (err u108))
(define-constant ERR-RECOVERY-EXISTS (err u109))
(define-constant ERR-RECOVERY-NOT-FOUND (err u110))
(define-constant ERR-INSUFFICIENT-BALANCE (err u111))
(define-constant ERR-WITHDRAWAL-NOT-READY (err u112))

;; Constants
(define-constant DEFAULT-COOLDOWN-PERIOD u144) ;; ~24 hours in Stacks blocks (approx. 10 min per block)
(define-constant DEFAULT-WITHDRAWAL-LIMIT u1000000000) ;; 1000 STX in uSTX
(define-constant MAX-WITHDRAW-AMOUNT u50000000000) ;; 50,000 STX limit by default
(define-constant MAX-DELEGATES u5) ;; Maximum number of delegates per vault

;; Data Maps
;; Vault structure holding configuration and balances
(define-map vaults
  { owner: principal }
  {
    balance: uint,                  ;; STX balance in uSTX
    withdrawal-limit: uint,         ;; Max withdrawal per day without confirmation
    cooldown-period: uint,          ;; Blocks to wait for large withdrawals
    daily-withdrawal-total: uint,   ;; Running total of withdrawals in current period
    last-withdrawal-height: uint,   ;; Block height of last withdrawal
    active: bool                    ;; Whether the vault is active
  }
)

;; Pending withdrawals awaiting confirmation after cooldown
(define-map pending-withdrawals
  { owner: principal, id: uint }
  {
    amount: uint,
    beneficiary: principal,
    initiated-at-block: uint,
    confirmation-code: (buff 32)
  }
)

;; Tracks withdrawal IDs per user
(define-map withdrawal-counters
  { owner: principal }
  { counter: uint }
)

;; Authorized delegates who can perform specific actions
(define-map delegates
  { vault-owner: principal, delegate: principal }
  {
    can-deposit: bool,
    can-initiate-withdrawal: bool,
    can-view-balance: bool,
    withdrawal-limit: uint,
    active: bool
  }
)

;; Recovery addresses for emergency access
(define-map recovery-addresses
  { vault-owner: principal, recovery: principal }
  {
    active: bool,
    last-updated: uint
  }
)

;; Activity log
(define-map activity-log
  { owner: principal, id: uint }
  {
    action: (string-utf8 20),
    amount: uint,
    timestamp: uint,
    related-principal: (optional principal)
  }
)

;; Activity log ID counter
(define-map activity-counters
  { owner: principal }
  { counter: uint }
)

;; Private Functions

;; Records an activity in the vault owner's log
(define-private (record-activity (owner principal) (action (string-utf8 20)) (amount uint) (related-principal (optional principal)))
  (let
    (
      (current-counter (default-to { counter: u0 } (map-get? activity-counters { owner: owner })))
      (current-id (get counter current-counter))
      (next-id (+ current-id u1))
    )
    (map-set activity-counters { owner: owner } { counter: next-id })
    (map-set activity-log 
      { owner: owner, id: current-id }
      {
        action: action,
        amount: amount,
        timestamp: block-height,
        related-principal: related-principal
      }
    )
    next-id
  )
)

;; Check if sender has delegate permission for a specific action
(define-private (is-authorized-delegate (vault-owner principal) (action (string-utf8 20)))
  (let
    (
      (delegate-info (map-get? delegates { vault-owner: vault-owner, delegate: tx-sender }))
    )
    (and
      (is-some delegate-info)
      (match delegate-info delegate-data
        (and 
          (get active delegate-data)
          (cond
            (or (is-eq action "deposit") (is-eq action "view")) (get can-deposit delegate-data)
            (is-eq action "withdraw") (get can-initiate-withdrawal delegate-data)
            (is-eq action "view-balance") (get can-view-balance delegate-data)
            false
          )
        )
        false
      )
    )
  )
)

;; Check if a principal can perform an action on a vault
(define-private (can-perform-action (vault-owner principal) (action (string-utf8 20)))
  (or 
    (is-eq tx-sender vault-owner)
    (is-authorized-delegate vault-owner action)
  )
)

;; Get a vault or return default values
(define-private (get-vault (owner principal))
  (default-to 
    {
      balance: u0,
      withdrawal-limit: DEFAULT-WITHDRAWAL-LIMIT,
      cooldown-period: DEFAULT-COOLDOWN-PERIOD,
      daily-withdrawal-total: u0,
      last-withdrawal-height: u0,
      active: false
    }
    (map-get? vaults { owner: owner })
  )
)

;; Reset daily withdrawal limit if a day has passed (144 blocks is roughly a day)
(define-private (refresh-daily-limit (vault-data (tuple (balance uint) (withdrawal-limit uint) (cooldown-period uint) (daily-withdrawal-total uint) (last-withdrawal-height uint) (active bool))))
  (let
    (
      (current-height block-height)
      (last-height (get last-withdrawal-height vault-data))
    )
    (if (> (- current-height last-height) u144)
      (merge vault-data { daily-withdrawal-total: u0, last-withdrawal-height: current-height })
      vault-data
    )
  )
)

;; Generate a new withdrawal ID for a user
(define-private (get-next-withdrawal-id (owner principal))
  (let
    (
      (counter-data (default-to { counter: u0 } (map-get? withdrawal-counters { owner: owner })))
      (current-id (get counter counter-data))
      (next-id (+ current-id u1))
    )
    (map-set withdrawal-counters { owner: owner } { counter: next-id })
    next-id
  )
)

;; Read-only Functions

;; Get vault information for an owner
(define-read-only (get-vault-info (owner principal))
  (if (can-perform-action owner "view-balance")
    (ok (get-vault owner))
    ERR-NOT-AUTHORIZED
  )
)

;; Get pending withdrawal information
(define-read-only (get-pending-withdrawal (owner principal) (id uint))
  (if (can-perform-action owner "withdraw")
    (match (map-get? pending-withdrawals { owner: owner, id: id })
      withdrawal (ok withdrawal)
      ERR-PENDING-WITHDRAWAL-NOT-FOUND
    )
    ERR-NOT-AUTHORIZED
  )
)

;; Get delegate information
(define-read-only (get-delegate-info (vault-owner principal) (delegate principal))
  (if (or (is-eq tx-sender vault-owner) (is-eq tx-sender delegate))
    (match (map-get? delegates { vault-owner: vault-owner, delegate: delegate })
      delegate-data (ok delegate-data)
      ERR-DELEGATE-NOT-FOUND
    )
    ERR-NOT-AUTHORIZED
  )
)

;; Check if a recovery address is configured
(define-read-only (get-recovery-status (vault-owner principal) (recovery principal))
  (if (or (is-eq tx-sender vault-owner) (is-eq tx-sender recovery))
    (match (map-get? recovery-addresses { vault-owner: vault-owner, recovery: recovery })
      recovery-data (ok recovery-data)
      ERR-RECOVERY-NOT-FOUND
    )
    ERR-NOT-AUTHORIZED
  )
)

;; Get activity log entry
(define-read-only (get-activity (owner principal) (id uint))
  (if (can-perform-action owner "view-balance")
    (match (map-get? activity-log { owner: owner, id: id })
      activity (ok activity)
      (err u404)
    )
    ERR-NOT-AUTHORIZED
  )
)

;; Public Functions

;; Create or update a vault
(define-public (create-vault (withdrawal-limit uint) (cooldown-period uint))
  (let
    (
      (existing-vault (map-get? vaults { owner: tx-sender }))
      (sanitized-limit (if (> withdrawal-limit MAX-WITHDRAW-AMOUNT) MAX-WITHDRAW-AMOUNT withdrawal-limit))
    )
    (map-set vaults
      { owner: tx-sender }
      {
        balance: (if (is-some existing-vault) (get balance (unwrap-panic existing-vault)) u0),
        withdrawal-limit: sanitized-limit,
        cooldown-period: cooldown-period,
        daily-withdrawal-total: u0,
        last-withdrawal-height: block-height,
        active: true
      }
    )
    (if (is-none existing-vault)
      (record-activity tx-sender "create-vault" u0 none)
      (record-activity tx-sender "update-vault" u0 none)
    )
    (ok true)
  )
)

;; Deposit STX into the vault
(define-public (deposit (owner principal) (amount uint))
  (let
    (
      (vault-data (get-vault owner))
    )
    (asserts! (or (is-eq tx-sender owner) (is-authorized-delegate owner "deposit")) ERR-NOT-AUTHORIZED)
    (asserts! (get active vault-data) ERR-VAULT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    (map-set vaults
      { owner: owner }
      (merge vault-data { balance: (+ (get balance vault-data) amount) })
    )
    
    (record-activity owner "deposit" amount (some tx-sender))
    (ok true)
  )
)

;; Initiate withdrawal - if under limit, completes immediately, otherwise enters cooldown
(define-public (initiate-withdrawal (owner principal) (amount uint) (beneficiary principal))
  (let
    (
      (vault-data (refresh-daily-limit (get-vault owner)))
      (withdrawal-limit (get withdrawal-limit vault-data))
      (daily-total (get daily-withdrawal-total vault-data))
      (new-daily-total (+ daily-total amount))
      (needs-cooldown (> amount withdrawal-limit))
    )
    (asserts! (can-perform-action owner "withdraw") ERR-NOT-AUTHORIZED)
    (asserts! (get active vault-data) ERR-VAULT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount (get balance vault-data)) ERR-INSUFFICIENT-BALANCE)
    
    (if needs-cooldown
      (let
        (
          (withdrawal-id (get-next-withdrawal-id owner))
          (confirmation-code (sha256 (concat (unwrap-panic (to-consensus-buff? amount)) 
                                            (unwrap-panic (to-consensus-buff? withdrawal-id)))))
        )
        (map-set pending-withdrawals
          { owner: owner, id: withdrawal-id }
          {
            amount: amount,
            beneficiary: beneficiary,
            initiated-at-block: block-height,
            confirmation-code: confirmation-code
          }
        )
        (record-activity owner "init-withdraw" amount (some beneficiary))
        (ok { withdrawal-id: withdrawal-id, needs-confirmation: true })
      )
      ;; Direct withdrawal for small amounts
      (begin
        (map-set vaults
          { owner: owner }
          (merge vault-data {
            balance: (- (get balance vault-data) amount),
            daily-withdrawal-total: new-daily-total,
            last-withdrawal-height: block-height
          })
        )
        
        (as-contract (stx-transfer? amount tx-sender beneficiary))
        
        (record-activity owner "withdraw" amount (some beneficiary))
        (ok { withdrawal-id: u0, needs-confirmation: false })
      )
    )
  )
)

;; Confirm a pending withdrawal after cooldown period
(define-public (confirm-withdrawal (owner principal) (withdrawal-id uint))
  (let
    (
      (withdrawal (map-get? pending-withdrawals { owner: owner, id: withdrawal-id }))
    )
    (asserts! (can-perform-action owner "withdraw") ERR-NOT-AUTHORIZED)
    (asserts! (is-some withdrawal) ERR-PENDING-WITHDRAWAL-NOT-FOUND)
    
    (let
      (
        (withdrawal-data (unwrap-panic withdrawal))
        (vault-data (refresh-daily-limit (get-vault owner)))
        (cooldown-blocks (get cooldown-period vault-data))
        (amount (get amount withdrawal-data))
        (beneficiary (get beneficiary withdrawal-data))
        (initiated-block (get initiated-at-block withdrawal-data))
      )
      (asserts! (>= block-height (+ initiated-block cooldown-blocks)) ERR-WITHDRAWAL-NOT-READY)
      (asserts! (<= amount (get balance vault-data)) ERR-INSUFFICIENT-BALANCE)
      
      ;; Update vault with new balance and track daily withdrawal
      (map-set vaults
        { owner: owner }
        (merge vault-data {
          balance: (- (get balance vault-data) amount),
          daily-withdrawal-total: (+ (get daily-withdrawal-total vault-data) amount),
          last-withdrawal-height: block-height
        })
      )
      
      ;; Delete pending withdrawal
      (map-delete pending-withdrawals { owner: owner, id: withdrawal-id })
      
      ;; Transfer STX to beneficiary
      (as-contract (stx-transfer? amount tx-sender beneficiary))
      
      (record-activity owner "confirm-withdraw" amount (some beneficiary))
      (ok true)
    )
  )
)

;; Cancel a pending withdrawal
(define-public (cancel-withdrawal (owner principal) (withdrawal-id uint))
  (let
    (
      (withdrawal (map-get? pending-withdrawals { owner: owner, id: withdrawal-id }))
    )
    (asserts! (can-perform-action owner "withdraw") ERR-NOT-AUTHORIZED)
    (asserts! (is-some withdrawal) ERR-PENDING-WITHDRAWAL-NOT-FOUND)
    
    (map-delete pending-withdrawals { owner: owner, id: withdrawal-id })
    
    (record-activity owner "cancel-withdraw" (get amount (unwrap-panic withdrawal)) none)
    (ok true)
  )
)

;; Add a delegate to the vault
(define-public (add-delegate 
  (delegate principal) 
  (can-deposit bool) 
  (can-initiate-withdrawal bool) 
  (can-view-balance bool)
  (withdrawal-limit uint))
  (let
    (
      (vault-data (get-vault tx-sender))
    )
    (asserts! (not (is-eq delegate tx-sender)) ERR-INVALID-AMOUNT) ;; Can't delegate to self
    (asserts! (get active vault-data) ERR-VAULT-NOT-FOUND)
    (asserts! (is-none (map-get? delegates { vault-owner: tx-sender, delegate: delegate })) ERR-DELEGATE-EXISTS)
    
    (map-set delegates
      { vault-owner: tx-sender, delegate: delegate }
      {
        can-deposit: can-deposit,
        can-initiate-withdrawal: can-initiate-withdrawal,
        can-view-balance: can-view-balance,
        withdrawal-limit: withdrawal-limit,
        active: true
      }
    )
    
    (record-activity tx-sender "add-delegate" u0 (some delegate))
    (ok true)
  )
)

;; Remove a delegate
(define-public (remove-delegate (delegate principal))
  (asserts! (is-some (map-get? delegates { vault-owner: tx-sender, delegate: delegate })) ERR-DELEGATE-NOT-FOUND)
  
  (map-delete delegates { vault-owner: tx-sender, delegate: delegate })
  
  (record-activity tx-sender "remove-delegate" u0 (some delegate))
  (ok true)
)

;; Add recovery address for emergency access
(define-public (add-recovery-address (recovery principal))
  (asserts! (not (is-eq recovery tx-sender)) ERR-INVALID-AMOUNT) ;; Can't recover to self
  (asserts! (is-none (map-get? recovery-addresses { vault-owner: tx-sender, recovery: recovery })) ERR-RECOVERY-EXISTS)
  
  (map-set recovery-addresses
    { vault-owner: tx-sender, recovery: recovery }
    {
      active: true,
      last-updated: block-height
    }
  )
  
  (record-activity tx-sender "add-recovery" u0 (some recovery))
  (ok true)
)

;; Remove recovery address
(define-public (remove-recovery-address (recovery principal))
  (asserts! (is-some (map-get? recovery-addresses { vault-owner: tx-sender, recovery: recovery })) ERR-RECOVERY-NOT-FOUND)
  
  (map-delete recovery-addresses { vault-owner: tx-sender, recovery: recovery })
  
  (record-activity tx-sender "remove-recovery" u0 (some recovery))
  (ok true)
)

;; Emergency recovery function - can be called by recovery address in emergency
;; This is simplified - in production would have more verification and time locks
(define-public (emergency-withdrawal (vault-owner principal) (amount uint) (beneficiary principal))
  (let
    (
      (recovery-data (map-get? recovery-addresses { vault-owner: vault-owner, recovery: tx-sender }))
      (vault-data (get-vault vault-owner))
    )
    (asserts! (is-some recovery-data) ERR-NOT-AUTHORIZED)
    (asserts! (get active (unwrap-panic recovery-data)) ERR-NOT-AUTHORIZED)
    (asserts! (get active vault-data) ERR-VAULT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount (get balance vault-data)) ERR-INSUFFICIENT-BALANCE)
    
    ;; Update vault
    (map-set vaults
      { owner: vault-owner }
      (merge vault-data {
        balance: (- (get balance vault-data) amount)
      })
    )
    
    ;; Transfer STX to beneficiary
    (as-contract (stx-transfer? amount tx-sender beneficiary))
    
    (record-activity vault-owner "emergency-withdraw" amount (some tx-sender))
    (ok true)
  )
)