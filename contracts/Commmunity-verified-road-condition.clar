;; title: Community-verified-road-condition
;; version: 1.0.0
;; summary: Community-driven road condition reporting and verification system
;; description: Drivers can submit road condition reports which are verified by the community and stored on-chain with rewards for contributors

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-REPORT-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-VOTED (err u102))
(define-constant ERR-INSUFFICIENT-STAKE (err u103))
(define-constant ERR-INVALID-CONDITION (err u104))
(define-constant ERR-REPORT-EXPIRED (err u105))
(define-constant ERR-ALREADY-VERIFIED (err u106))

(define-constant MIN-STAKE u1000000)
(define-constant REWARD-AMOUNT u500000)
(define-constant VERIFICATION-THRESHOLD u3)
(define-constant REPORT-EXPIRY-BLOCKS u144)

(define-data-var next-report-id uint u1)
(define-data-var total-verified-reports uint u0)

(define-map road-reports
    { report-id: uint }
    {
        reporter: principal,
        latitude: int,
        longitude: int,
        condition: (string-ascii 20),
        severity: uint,
        description: (string-utf8 256),
        timestamp: uint,
        stake: uint,
        verified: bool,
        verification-count: uint,
        reward-claimed: bool
    }
)

(define-map user-stats
    { user: principal }
    {
        reports-submitted: uint,
        reports-verified: uint,
        total-rewards: uint,
        reputation-score: uint,
        active-stake: uint
    }
)

(define-map report-verifications
    { report-id: uint, verifier: principal }
    { voted: bool, vote: bool, stake: uint }
)

(define-map location-reports
    { latitude: int, longitude: int }
    { latest-report-id: uint, report-count: uint }
)

(define-public (submit-report (lat int) (lng int) (condition (string-ascii 20)) (severity uint) (desc (string-utf8 256)))
    (let (
        (report-id (var-get next-report-id))
        (current-block stacks-block-height)
        (stake-amount (if (> severity u7) MIN-STAKE (/ MIN-STAKE u2)))
    )
        (asserts! (<= severity u10) ERR-INVALID-CONDITION)
        (asserts! (>= (stx-get-balance tx-sender) stake-amount) ERR-INSUFFICIENT-STAKE)
        
        (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
        
        (map-set road-reports
            { report-id: report-id }
            {
                reporter: tx-sender,
                latitude: lat,
                longitude: lng,
                condition: condition,
                severity: severity,
                description: desc,
                timestamp: current-block,
                stake: stake-amount,
                verified: false,
                verification-count: u0,
                reward-claimed: false
            }
        )
        
        (map-set location-reports
            { latitude: lat, longitude: lng }
            { 
                latest-report-id: report-id,
                report-count: (+ (default-to u0 (get report-count (map-get? location-reports { latitude: lat, longitude: lng }))) u1)
            }
        )
        
        (update-user-stats tx-sender "submit")
        (var-set next-report-id (+ report-id u1))
        (ok report-id)
    )
)

(define-public (verify-report (report-id uint) (vote bool))
    (let (
        (report (unwrap! (map-get? road-reports { report-id: report-id }) ERR-REPORT-NOT-FOUND))
        (verifier-stake (if vote MIN-STAKE (/ MIN-STAKE u2)))
        (current-block stacks-block-height)
        (report-age (- current-block (get timestamp report)))
    )
        (asserts! (not (get verified report)) ERR-ALREADY-VERIFIED)
        (asserts! (<= report-age REPORT-EXPIRY-BLOCKS) ERR-REPORT-EXPIRED)
        (asserts! (is-none (map-get? report-verifications { report-id: report-id, verifier: tx-sender })) ERR-ALREADY-VOTED)
        (asserts! (>= (stx-get-balance tx-sender) verifier-stake) ERR-INSUFFICIENT-STAKE)
        
        (try! (stx-transfer? verifier-stake tx-sender (as-contract tx-sender)))
        
        (map-set report-verifications
            { report-id: report-id, verifier: tx-sender }
            { voted: true, vote: vote, stake: verifier-stake }
        )
        
        (let ((new-verification-count (+ (get verification-count report) u1)))
            (map-set road-reports
                { report-id: report-id }
                (merge report { verification-count: new-verification-count })
            )
            
            (if (>= new-verification-count VERIFICATION-THRESHOLD)
                (finalize-verification report-id)
                (ok true)
            )
        )
    )
)

(define-private (finalize-verification (report-id uint))
    (let (
        (report (unwrap-panic (map-get? road-reports { report-id: report-id })))
        (total-votes (get verification-count report))
        (is-verified (>= total-votes VERIFICATION-THRESHOLD))
    )
        (map-set road-reports
            { report-id: report-id }
            (merge report { verified: is-verified })
        )
        
        (if is-verified
            (begin
                (var-set total-verified-reports (+ (var-get total-verified-reports) u1))
                (distribute-rewards report-id)
            )
            (begin
                (try! (as-contract (stx-transfer? (get stake report) tx-sender (get reporter report))))
                (ok true)
            )
        )
    )
)

(define-private (distribute-rewards (report-id uint))
    (let ((report (unwrap-panic (map-get? road-reports { report-id: report-id }))))
        (try! (as-contract (stx-transfer? REWARD-AMOUNT tx-sender (get reporter report))))
        (update-user-stats (get reporter report) "verify")
        (ok true)
    )
)

(define-public (claim-verification-rewards (report-id uint))
    (let (
        (report (unwrap! (map-get? road-reports { report-id: report-id }) ERR-REPORT-NOT-FOUND))
        (verification (unwrap! (map-get? report-verifications { report-id: report-id, verifier: tx-sender }) ERR-NOT-AUTHORIZED))
    )
        (asserts! (get verified report) ERR-REPORT-NOT-FOUND)
        (asserts! (get vote verification) ERR-NOT-AUTHORIZED)
        
        (try! (as-contract (stx-transfer? (get stake verification) tx-sender tx-sender)))
        (try! (as-contract (stx-transfer? (/ REWARD-AMOUNT u3) tx-sender tx-sender)))
        
        (update-user-stats tx-sender "reward")
        (ok true)
    )
)

(define-private (update-user-stats (user principal) (action (string-ascii 10)))
    (let (
        (current-stats (default-to 
            { reports-submitted: u0, reports-verified: u0, total-rewards: u0, reputation-score: u0, active-stake: u0 }
            (map-get? user-stats { user: user })
        ))
    )
        (if (is-eq action "submit")
            (map-set user-stats
                { user: user }
                (merge current-stats { 
                    reports-submitted: (+ (get reports-submitted current-stats) u1),
                    reputation-score: (+ (get reputation-score current-stats) u10)
                })
            )
            (if (is-eq action "verify")
                (map-set user-stats
                    { user: user }
                    (merge current-stats { 
                        reports-verified: (+ (get reports-verified current-stats) u1),
                        total-rewards: (+ (get total-rewards current-stats) REWARD-AMOUNT),
                        reputation-score: (+ (get reputation-score current-stats) u50)
                    })
                )
                (map-set user-stats
                    { user: user }
                    (merge current-stats { 
                        total-rewards: (+ (get total-rewards current-stats) (/ REWARD-AMOUNT u3)),
                        reputation-score: (+ (get reputation-score current-stats) u5)
                    })
                )
            )
        )
    )
)

(define-read-only (get-report (report-id uint))
    (map-get? road-reports { report-id: report-id })
)

(define-read-only (get-user-stats (user principal))
    (map-get? user-stats { user: user })
)

(define-read-only (get-location-reports (lat int) (lng int))
    (map-get? location-reports { latitude: lat, longitude: lng })
)

(define-read-only (get-total-reports)
    (- (var-get next-report-id) u1)
)

(define-read-only (get-total-verified-reports)
    (var-get total-verified-reports)
)

(define-read-only (get-verification (report-id uint) (verifier principal))
    (map-get? report-verifications { report-id: report-id, verifier: verifier })
)

(define-read-only (is-report-expired (report-id uint))
    (match (map-get? road-reports { report-id: report-id })
        report
        (let ((report-age (- stacks-block-height (get timestamp report))))
            (> report-age REPORT-EXPIRY-BLOCKS)
        )
        true
    )
)

(define-read-only (get-recent-reports (limit uint))
    (let ((current-id (var-get next-report-id)))
        (if (> current-id limit)
            (map get-report (list (- current-id u1) (- current-id u2) (- current-id u3) (- current-id u4) (- current-id u5)))
            (map get-report (list u1 u2 u3 u4 u5))
        )
    )
)

(define-read-only (calculate-user-reputation (user principal))
    (match (map-get? user-stats { user: user })
        stats
        (let (
            (base-score (get reputation-score stats))
            (reports (get reports-submitted stats))
            (verifications (get reports-verified stats))
            (bonus (+ (* reports u5) (* verifications u15)))
        )
            (+ base-score bonus)
        )
        u0
    )
)

(define-public (emergency-pause)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (ok true)
    )
)
