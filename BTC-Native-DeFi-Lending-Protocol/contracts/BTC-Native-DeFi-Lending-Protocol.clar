
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
