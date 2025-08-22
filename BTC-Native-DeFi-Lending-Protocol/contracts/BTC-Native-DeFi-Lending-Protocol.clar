
;; title: BTC-Native-DeFi-Lending-Protocol
;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u101))
(define-constant ERR_INSUFFICIENT_FUNDS (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_INVALID_ASSET (err u104))
(define-constant ERR_BORROW_LIMIT_REACHED (err u105))
(define-constant ERR_NOT_LIQUIDATABLE (err u106))
(define-constant ERR_POSITION_NOT_FOUND (err u107))
(define-constant ERR_ORACLE_DATA_EXPIRED (err u108))
(define-constant ERR_PROTOCOL_PAUSED (err u109))

;; Protocol parameters (adjustable by governance)
(define-data-var liquidation-threshold uint u750) ;; 75% expressed as basis points
(define-data-var liquidation-incentive uint u108) ;; 8% bonus for liquidators (multiplier 1.08)
(define-data-var protocol-fee uint u50) ;; 5% of interest goes to protocol
(define-data-var protocol-paused bool false) ;; Emergency pause switch
(define-data-var minimum-collateral-value uint u500000000) ;; Minimum 500 STX worth of collateral

;; Interest rate model parameters
(define-data-var base-rate uint u20) ;; 2% base interest rate
(define-data-var rate-multiplier uint u120) ;; Rate increase multiplier
(define-data-var optimal-utilization uint u800) ;; 80% optimal utilization rate
(define-data-var reserve-factor uint u100) ;; 10% of interest goes to reserves

;; SIP-010 compliant tokens that can be used as collateral or borrowed
(define-map supported-assets 
  { asset-contract: principal }
  {
    collateral-factor: uint, ;; max borrow value per collateral value (75% = 750)
    borrow-enabled: bool, 
    collateral-enabled: bool,
    price-oracle: principal ;; Oracle contract with get-price function
  }
)

;; Protocol reserves
(define-map token-reserves 
  { asset-contract: principal }
  { amount: uint }
)

;; Market data per asset
(define-map market-data
  { asset-contract: principal }
  {
    total-supplied: uint,
    total-borrowed: uint,
    supply-apy: uint,
    borrow-apy: uint,
    last-update-block: uint
  }
)

;; User collateral deposits
(define-map user-collateral
  { user: principal, asset-contract: principal }
  { amount: uint }
)

;; User borrows
(define-map user-borrows
  { user: principal, asset-contract: principal }
  {
    principal: uint,
    interest-index: uint,
    last-update-block: uint
  }
)

;; Data persistence for pending BTC collateral operations
(define-map pending-btc-collateral
  { bitcoin-tx-id: (buff 32) }
  {
    user: principal,
    amount: uint,
    status: (string-ascii 20)
  }
)

;; Contract initialization
(define-data-var contract-initialized bool false)

;; Access control - only contract owner
(define-private (check-owner)
  (if (is-eq tx-sender CONTRACT_OWNER)
    (ok true)
    ERR_UNAUTHORIZED
  )
)

;; Access control - check if protocol is operational
(define-private (check-protocol-active)
  (if (var-get protocol-paused)
    ERR_PROTOCOL_PAUSED
    (ok true)
  )
)


;; Initialize protocol with initial supported assets
(define-public (initialize-protocol (initial-assets (list 10 principal)))
  (begin
    (asserts! (not (var-get contract-initialized)) ERR_UNAUTHORIZED)
    (var-set contract-initialized true)
    (ok true)
  )
)


;; Add or update a supported asset
(define-public (set-supported-asset 
    (asset-contract principal)
    (collateral-factor uint)
    (borrow-enabled bool)
    (collateral-enabled bool)
    (price-oracle principal)
  )
  (begin
    (try! (check-owner))
    (asserts! (<= collateral-factor u900) (err u110)) ;; Max 90% collateral factor
    
    (map-set supported-assets
      { asset-contract: asset-contract }
      {
        collateral-factor: collateral-factor,
        borrow-enabled: borrow-enabled,
        collateral-enabled: collateral-enabled,
        price-oracle: price-oracle
      }
    )
    
    ;; Initialize market data if it doesn't exist
    (map-insert market-data
      { asset-contract: asset-contract }
      {
        total-supplied: u0,
        total-borrowed: u0,
        supply-apy: u0,
        borrow-apy: (var-get base-rate),
        last-update-block: stacks-block-height
      }
    )
    
    ;; Initialize reserves if they don't exist
    (map-insert token-reserves
      { asset-contract: asset-contract }
      { amount: u0 }
    )
    
    (ok true)
  )
)

;; Update protocol parameters
(define-public (update-protocol-parameters
    (new-liquidation-threshold (optional uint))
    (new-liquidation-incentive (optional uint))
    (new-protocol-fee (optional uint))
  )
  (begin
    (try! (check-owner))
    
    ;; Update each parameter if provided
    (if (is-some new-liquidation-threshold)
      (var-set liquidation-threshold (unwrap-panic new-liquidation-threshold))
      true
    )
    
    (if (is-some new-liquidation-incentive)
      (var-set liquidation-incentive (unwrap-panic new-liquidation-incentive))
      true
    )
    
    (if (is-some new-protocol-fee)
      (var-set protocol-fee (unwrap-panic new-protocol-fee))
      true
    )
    
    (ok true)
  )
)

;; Update interest rate model parameters
(define-public (update-interest-rate-model
    (new-base-rate (optional uint))
    (new-rate-multiplier (optional uint))
    (new-optimal-utilization (optional uint))
    (new-reserve-factor (optional uint))
  )
  (begin
    (try! (check-owner))
    
    ;; Update each parameter if provided
    (if (is-some new-base-rate)
      (var-set base-rate (unwrap-panic new-base-rate))
      true
    )
    
    (if (is-some new-rate-multiplier)
      (var-set rate-multiplier (unwrap-panic new-rate-multiplier))
      true
    )
    
    (if (is-some new-optimal-utilization)
      (var-set optimal-utilization (unwrap-panic new-optimal-utilization))
      true
    )
    
    (if (is-some new-reserve-factor)
      (var-set reserve-factor (unwrap-panic new-reserve-factor))
      true
    )
    
    (ok true)
  )
)

;; Emergency pause for all protocol operations
(define-public (set-protocol-pause (paused bool))
  (begin
    (try! (check-owner))
    (var-set protocol-paused paused)
    (ok true)
  )
)

;; Register pending BTC collateral operation
(define-public (register-btc-collateral (bitcoin-tx-id (buff 32)) (amount uint))
  (begin
    (try! (check-protocol-active))
    
    ;; Store the pending BTC collateral operation
    (map-set pending-btc-collateral
      { bitcoin-tx-id: bitcoin-tx-id }
      {
        user: tx-sender,
        amount: amount,
        status: "pending"
      }
    )
    
    (ok true)
  )
)

;; For simplicity, we'll include a fixed list
(define-private (get-all-asset-contracts)
  (list 
    'SP000000000000000000002Q6VF78.sbtc
    'SP000000000000000000002Q6VF78.usda
  )
)

(define-constant ERR_FLASH_LOAN_NOT_REPAID (err u200))
(define-constant ERR_FLASH_LOAN_FEE_NOT_PAID (err u201))
(define-constant ERR_FLASH_LOAN_AMOUNT_TOO_HIGH (err u202))

(define-data-var flash-loan-fee uint u9) ;; 0.09% flash loan fee (9 basis points)
(define-data-var max-flash-loan-ratio uint u800) ;; Max 80% of available liquidity

;; Flash loan execution tracking
(define-map active-flash-loans
  { loan-id: uint }
  {
    borrower: principal,
    asset: principal,
    amount: uint,
    fee: uint,
    repaid: bool
  }
)

(define-private (verify-flash-loan-repayment (loan-id uint))
  (let 
    (
      (loan-data (unwrap! (map-get? active-flash-loans { loan-id: loan-id }) ERR_FLASH_LOAN_NOT_REPAID))
      (required-amount (+ (get amount loan-data) (get fee loan-data)))
    )
    
    ;; Mark as repaid (simplified verification)
    (map-set active-flash-loans
      { loan-id: loan-id }
      (merge loan-data { repaid: true })
    )
    
    (ok true)
  )
)

(define-constant ERR_REWARD_CALCULATION_FAILED (err u210))
(define-constant ERR_INSUFFICIENT_REWARDS (err u211))

;; Reward token (could be a governance token)
(define-data-var reward-token principal 'SP000000000000000000002Q6VF78.reward-token)
(define-data-var total-reward-pool uint u1000000000000) ;; 1M reward tokens
(define-data-var reward-per-block uint u100) ;; Rewards distributed per block

;; User reward tracking
(define-map user-rewards
  { user: principal }
  {
    pending-rewards: uint,
    last-claim-block: uint,
    total-claimed: uint
  }
)

;; Market reward multipliers
(define-map market-reward-multipliers
  { asset-contract: principal }
  { supply-multiplier: uint, borrow-multiplier: uint }
)

(define-public (set-reward-multipliers 
    (asset-contract principal) 
    (supply-multiplier uint) 
    (borrow-multiplier uint)
  )
  (begin
    (try! (check-owner))
    (map-set market-reward-multipliers
      { asset-contract: asset-contract }
      { supply-multiplier: supply-multiplier, borrow-multiplier: borrow-multiplier }
    )
    (ok true)
  )
)

(define-public (claim-rewards)
  (let 
    (
      (user-reward-data (default-to 
        { pending-rewards: u0, last-claim-block: u0, total-claimed: u0 }
        (map-get? user-rewards { user: tx-sender })
      ))
      (pending-amount (get pending-rewards user-reward-data))
    )
    
    (asserts! (> pending-amount u0) ERR_INSUFFICIENT_REWARDS)
    
    ;; Update user rewards
    (map-set user-rewards
      { user: tx-sender }
      {
        pending-rewards: u0,
        last-claim-block: stacks-block-height,
        total-claimed: (+ (get total-claimed user-reward-data) pending-amount)
      }
    )
    
    ;; Transfer rewards (simplified)
    (ok pending-amount)
  )
)

(define-constant ERR_PROPOSAL_NOT_FOUND (err u220))
(define-constant ERR_VOTING_PERIOD_ENDED (err u221))
(define-constant ERR_ALREADY_VOTED (err u222))
(define-constant ERR_INSUFFICIENT_VOTING_POWER (err u223))

(define-data-var min-proposal-threshold uint u100000) ;; Min tokens needed to create proposal
(define-data-var voting-period uint u1008) ;; ~1 week in blocks
(define-data-var quorum-threshold uint u400) ;; 40% quorum required

;; Proposal tracking
(define-map proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    for-votes: uint,
    against-votes: uint,
    start-block: uint,
    end-block: uint,
    executed: bool,
    action-type: (string-ascii 50) ;; "parameter-change", "asset-addition", etc.
  }
)

(define-constant ERR_PROTECTION_ALREADY_ACTIVE (err u240))
(define-constant ERR_PROTECTION_NOT_FOUND (err u241))

(define-map liquidation-protection
  { user: principal }
  {
    protection-fee-paid: uint,
    protection-expires: uint,
    max-protection-amount: uint
  }
)

(define-data-var protection-fee-rate uint u50) ;; 0.5% fee for protection

(define-public (purchase-liquidation-protection (protection-amount uint) (duration-blocks uint))
  (let 
    (
      (fee (/ (* protection-amount (var-get protection-fee-rate)) u10000))
      (expiry-block (+ stacks-block-height duration-blocks))
    )
    
    (asserts! (is-none (map-get? liquidation-protection { user: tx-sender })) ERR_PROTECTION_ALREADY_ACTIVE)
    
    (map-set liquidation-protection
      { user: tx-sender }
      {
        protection-fee-paid: fee,
        protection-expires: expiry-block,
        max-protection-amount: protection-amount
      }
    )
    
    (ok true)
  )
)

(define-constant ERR_BRIDGE_OPERATION_FAILED (err u250))
(define-constant ERR_INVALID_CHAIN_ID (err u251))

(define-map cross-chain-operations
  { operation-id: uint }
  {
    user: principal,
    source-chain: uint,
    dest-chain: uint,
    asset: principal,
    amount: uint,
    status: (string-ascii 20)
  }
)

(define-data-var next-operation-id uint u1)

(define-public (initiate-cross-chain-transfer 
    (dest-chain uint) 
    (asset-contract principal) 
    (amount uint)
  )
  (let 
    (
      (operation-id (var-get next-operation-id))
    )
    
    (try! (check-protocol-active))
    
    (map-set cross-chain-operations
      { operation-id: operation-id }
      {
        user: tx-sender,
        source-chain: u1, ;; Stacks chain ID
        dest-chain: dest-chain,
        asset: asset-contract,
        amount: amount,
        status: "initiated"
      }
    )
    
    (var-set next-operation-id (+ operation-id u1))
    (ok operation-id)
  )
)

(define-constant ERR_INVALID_TRIGGER_PRICE (err u260))
(define-constant ERR_ORDER_NOT_FOUND (err u261))

(define-map automated-orders
  { order-id: uint }
  {
    user: principal,
    order-type: (string-ascii 20), ;; "stop-loss", "take-profit", "auto-repay"
    asset: principal,
    trigger-price: uint,
    amount: uint,
    active: bool
  }
)

(define-data-var next-order-id uint u1)

(define-public (create-stop-loss-order 
    (asset-contract principal) 
    (trigger-price uint) 
    (amount uint)
  )
  (let 
    (
      (order-id (var-get next-order-id))
    )
    
    (asserts! (> trigger-price u0) ERR_INVALID_TRIGGER_PRICE)
    
    (map-set automated-orders
      { order-id: order-id }
      {
        user: tx-sender,
        order-type: "stop-loss",
        asset: asset-contract,
        trigger-price: trigger-price,
        amount: amount,
        active: true
      }
    )
    
    (var-set next-order-id (+ order-id u1))
    (ok order-id)
  )
)
(define-map daily-protocol-stats
  { date: uint }
  {
    total-value-locked: uint,
    total-borrowed: uint,
    daily-volume: uint,
    active-users: uint,
    liquidations-count: uint
  }
)

(define-map user-activity-stats
  { user: principal }
  {
    total-supplied: uint,
    total-borrowed: uint,
    liquidations-experienced: uint,
    last-activity-block: uint,
    rewards-earned: uint
  }
)

(define-public (update-daily-stats 
    (date uint) 
    (tvl uint) 
    (total-borrowed uint) 
    (volume uint) 
    (users uint) 
    (liquidations uint)
  )
  (begin
    (try! (check-owner))
    (map-set daily-protocol-stats
      { date: date }
      {
        total-value-locked: tvl,
        total-borrowed: total-borrowed,
        daily-volume: volume,
        active-users: users,
        liquidations-count: liquidations
      }
    )
    (ok true)
  )
)
