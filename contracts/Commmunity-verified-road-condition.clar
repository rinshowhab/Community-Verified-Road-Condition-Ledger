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
(define-constant ERR-INVALID-ROUTE (err u107))
(define-constant ERR-ROUTE-TOO-LONG (err u108))
(define-constant ERR-BOUNTY-NOT-FOUND (err u109))
(define-constant ERR-BOUNTY-ALREADY-FULFILLED (err u110))
(define-constant ERR-BOUNTY-EXPIRED (err u111))
(define-constant ERR-INVALID-BOUNTY (err u112))

(define-constant MIN-STAKE u1000000)
(define-constant REWARD-AMOUNT u500000)
(define-constant VERIFICATION-THRESHOLD u3)
(define-constant REPORT-EXPIRY-BLOCKS u144)
(define-constant QUALITY-DECAY-RATE u5)
(define-constant MAX-QUALITY-SCORE u1000)
(define-constant BOUNTY-EXPIRY-BLOCKS u1008)

(define-data-var next-report-id uint u1)
(define-data-var total-verified-reports uint u0)
(define-data-var next-bounty-id uint u1)

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

(define-map road-quality-index
    { latitude: int, longitude: int }
    {
        quality-score: uint,
        confidence-level: uint,
        last-updated: uint,
        trend-direction: (string-ascii 10),
        historical-average: uint
    }
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
                (try! (update-quality-index report-id))
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

(define-private (update-quality-index (report-id uint))
    (let (
        (report (unwrap! (map-get? road-reports { report-id: report-id }) ERR-REPORT-NOT-FOUND))
        (location-key { latitude: (get latitude report), longitude: (get longitude report) })
        (current-index (default-to 
            { quality-score: (/ MAX-QUALITY-SCORE u2), confidence-level: u0, last-updated: u0, trend-direction: "stable", historical-average: u0 }
            (map-get? road-quality-index location-key)))
        (time-decay (- stacks-block-height (get last-updated current-index)))
        (decayed-score (if (> time-decay u0)
            (if (> (get quality-score current-index) (* time-decay QUALITY-DECAY-RATE))
                (- (get quality-score current-index) (* time-decay QUALITY-DECAY-RATE))
                u0)
            (get quality-score current-index)))
        (report-impact (- MAX-QUALITY-SCORE (* (get severity report) u100)))
        (confidence-weight (+ u10 (get verification-count report)))
        (new-score (/ (+ (* decayed-score (get confidence-level current-index)) (* report-impact confidence-weight))
                      (+ (get confidence-level current-index) confidence-weight)))
        (new-confidence (+ (get confidence-level current-index) confidence-weight))
    )
        (map-set road-quality-index location-key
            {
                quality-score: new-score,
                confidence-level: new-confidence,
                last-updated: stacks-block-height,
                trend-direction: (if (> new-score (get quality-score current-index)) "improving" "declining"),
                historical-average: (/ (+ (* (get historical-average current-index) (get confidence-level current-index)) new-score)
                                       (+ (get confidence-level current-index) u1))
            })
        (ok true)
    )
)

(define-read-only (get-road-quality (lat int) (lng int))
    (match (map-get? road-quality-index { latitude: lat, longitude: lng })
        index
        (let (
            (time-decay (- stacks-block-height (get last-updated index)))
            (decayed-score (if (> time-decay u0)
                (if (> (get quality-score index) (* time-decay QUALITY-DECAY-RATE))
                    (- (get quality-score index) (* time-decay QUALITY-DECAY-RATE))
                    u0)
                (get quality-score index)))
        )
            (ok { quality-score: decayed-score, confidence: (get confidence-level index), trend: (get trend-direction index) }))
        (err ERR-REPORT-NOT-FOUND)
    )
)

(define-read-only (compare-route-quality (lat1 int) (lng1 int) (lat2 int) (lng2 int))
    (let (
        (location1-data (unwrap! (get-road-quality lat1 lng1) (ok { better-route: "unknown", quality-difference: u0 })))
        (location2-data (unwrap! (get-road-quality lat2 lng2) (ok { better-route: "unknown", quality-difference: u0 })))
        (location1-quality (get quality-score location1-data))
        (location2-quality (get quality-score location2-data))
    )
        (ok {
            better-route: (if (> location1-quality location2-quality) "route1" "route2"),
            quality-difference: (if (> location1-quality location2-quality) 
                                   (- location1-quality location2-quality) 
                                   (- location2-quality location1-quality))
        })
    )
)

(define-map bounties
    { bounty-id: uint }
    {
        creator: principal,
        latitude: int,
        longitude: int,
        reward: uint,
        description: (string-utf8 256),
        created-at: uint,
        fulfilled: bool,
        fulfiller: (optional principal),
        fulfilled-report-id: (optional uint)
    }
)

(define-map location-bounties
    { latitude: int, longitude: int }
    { active-bounty-id: uint }
)

(define-public (create-bounty (lat int) (lng int) (reward uint) (desc (string-utf8 256)))
    (let (
        (bounty-id (var-get next-bounty-id))
    )
        (asserts! (>= reward MIN-STAKE) ERR-INVALID-BOUNTY)
        (asserts! (>= (stx-get-balance tx-sender) reward) ERR-INSUFFICIENT-STAKE)

        (try! (stx-transfer? reward tx-sender (as-contract tx-sender)))

        (map-set bounties
            { bounty-id: bounty-id }
            {
                creator: tx-sender,
                latitude: lat,
                longitude: lng,
                reward: reward,
                description: desc,
                created-at: stacks-block-height,
                fulfilled: false,
                fulfiller: none,
                fulfilled-report-id: none
            }
        )

        (map-set location-bounties
            { latitude: lat, longitude: lng }
            { active-bounty-id: bounty-id }
        )

        (var-set next-bounty-id (+ bounty-id u1))
        (ok bounty-id)
    )
)

(define-public (fulfill-bounty (bounty-id uint) (report-id uint))
    (let (
        (bounty (unwrap! (map-get? bounties { bounty-id: bounty-id }) ERR-BOUNTY-NOT-FOUND))
        (report (unwrap! (map-get? road-reports { report-id: report-id }) ERR-REPORT-NOT-FOUND))
        (bounty-age (- stacks-block-height (get created-at bounty)))
        (fulfiller tx-sender)
    )
        (asserts! (not (get fulfilled bounty)) ERR-BOUNTY-ALREADY-FULFILLED)
        (asserts! (<= bounty-age BOUNTY-EXPIRY-BLOCKS) ERR-BOUNTY-EXPIRED)
        (asserts! (get verified report) ERR-REPORT-NOT-FOUND)
        (asserts! (is-eq (get latitude report) (get latitude bounty)) ERR-INVALID-BOUNTY)
        (asserts! (is-eq (get longitude report) (get longitude bounty)) ERR-INVALID-BOUNTY)
        (asserts! (is-eq (get reporter report) tx-sender) ERR-NOT-AUTHORIZED)

        (try! (as-contract (stx-transfer? (get reward bounty) tx-sender fulfiller)))

        (map-set bounties
            { bounty-id: bounty-id }
            (merge bounty {
                fulfilled: true,
                fulfiller: (some fulfiller),
                fulfilled-report-id: (some report-id)
            })
        )

        (ok true)
    )
)

(define-public (cancel-bounty (bounty-id uint))
    (let (
        (bounty (unwrap! (map-get? bounties { bounty-id: bounty-id }) ERR-BOUNTY-NOT-FOUND))
        (bounty-age (- stacks-block-height (get created-at bounty)))
        (creator tx-sender)
    )
        (asserts! (is-eq (get creator bounty) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (not (get fulfilled bounty)) ERR-BOUNTY-ALREADY-FULFILLED)
        (asserts! (> bounty-age BOUNTY-EXPIRY-BLOCKS) ERR-BOUNTY-EXPIRED)

        (try! (as-contract (stx-transfer? (get reward bounty) tx-sender creator)))

        (map-set bounties
            { bounty-id: bounty-id }
            (merge bounty { fulfilled: true })
        )

        (ok true)
    )
)

(define-read-only (get-bounty (bounty-id uint))
    (map-get? bounties { bounty-id: bounty-id })
)

(define-read-only (get-location-bounty (lat int) (lng int))
    (map-get? location-bounties { latitude: lat, longitude: lng })
)

(define-read-only (is-bounty-expired (bounty-id uint))
    (match (map-get? bounties { bounty-id: bounty-id })
        bounty
        (let ((bounty-age (- stacks-block-height (get created-at bounty))))
            (> bounty-age BOUNTY-EXPIRY-BLOCKS)
        )
        true
    )
)

(define-map route-analyses
    { route-hash: (buff 32) }
    {
        waypoint-count: uint,
        average-quality: uint,
        minimum-quality: uint,
        overall-confidence: uint,
        hazard-count: uint,
        analysis-timestamp: uint,
        requester: principal
    }
)

(define-data-var route-analysis-count uint u0)

(define-private (calculate-point-quality (waypoint {lat: int, lng: int}) (accumulator {total: uint, count: uint, min: uint, hazards: uint, confidence: uint}))
    (let (
        (quality-result (get-road-quality (get lat waypoint) (get lng waypoint)))
    )
        (match quality-result
            ok-data
            (let (
                (quality (get quality-score ok-data))
                (conf (get confidence ok-data))
                (current-min (get min accumulator))
                (is-hazard (< quality u300))
            )
                {
                    total: (+ (get total accumulator) quality),
                    count: (+ (get count accumulator) u1),
                    min: (if (or (is-eq current-min u0) (< quality current-min)) quality current-min),
                    hazards: (+ (get hazards accumulator) (if is-hazard u1 u0)),
                    confidence: (+ (get confidence accumulator) conf)
                }
            )
            err-val accumulator
        )
    )
)

(define-read-only (analyze-route (waypoints (list 20 {lat: int, lng: int})))
    (let (
        (waypoint-count (len waypoints))
        (analysis-result (fold calculate-point-quality waypoints {total: u0, count: u0, min: u0, hazards: u0, confidence: u0}))
        (total-quality (get total analysis-result))
        (point-count (get count analysis-result))
        (min-quality (get min analysis-result))
        (hazard-count (get hazards analysis-result))
        (total-confidence (get confidence analysis-result))
    )
        (asserts! (> waypoint-count u0) ERR-INVALID-ROUTE)
        (asserts! (<= waypoint-count u20) ERR-ROUTE-TOO-LONG)
        
        (if (is-eq point-count u0)
            (ok {
                average-quality: u0,
                minimum-quality: u0,
                overall-confidence: u0,
                hazard-count: u0,
                waypoint-count: waypoint-count,
                points-analyzed: u0,
                route-rating: "unknown",
                recommendation: "no-data"
            })
            (let (
                (avg-quality (/ total-quality point-count))
                (avg-confidence (/ total-confidence point-count))
                (route-rating (if (>= avg-quality u700) "excellent"
                              (if (>= avg-quality u500) "good"
                              (if (>= avg-quality u300) "fair"
                              "poor"))))
                (recommendation (if (> hazard-count u2) "avoid"
                                (if (< min-quality u200) "caution"
                                (if (>= avg-quality u600) "recommended"
                                "acceptable"))))
            )
                (ok {
                    average-quality: avg-quality,
                    minimum-quality: min-quality,
                    overall-confidence: avg-confidence,
                    hazard-count: hazard-count,
                    waypoint-count: waypoint-count,
                    points-analyzed: point-count,
                    route-rating: route-rating,
                    recommendation: recommendation
                })
            )
        )
    )
)

(define-public (save-route-analysis (waypoints (list 20 {lat: int, lng: int})) (route-hash (buff 32)))
    (let (
        (analysis (unwrap! (analyze-route waypoints) ERR-INVALID-ROUTE))
    )
        (map-set route-analyses
            { route-hash: route-hash }
            {
                waypoint-count: (get waypoint-count analysis),
                average-quality: (get average-quality analysis),
                minimum-quality: (get minimum-quality analysis),
                overall-confidence: (get overall-confidence analysis),
                hazard-count: (get hazard-count analysis),
                analysis-timestamp: stacks-block-height,
                requester: tx-sender
            }
        )
        (var-set route-analysis-count (+ (var-get route-analysis-count) u1))
        (ok true)
    )
)

(define-read-only (get-saved-route-analysis (route-hash (buff 32)))
    (map-get? route-analyses { route-hash: route-hash })
)

(define-read-only (get-total-route-analyses)
    (var-get route-analysis-count)
)

(define-read-only (compare-routes (route1 (list 20 {lat: int, lng: int})) (route2 (list 20 {lat: int, lng: int})))
    (let (
        (analysis1 (unwrap! (analyze-route route1) ERR-INVALID-ROUTE))
        (analysis2 (unwrap! (analyze-route route2) ERR-INVALID-ROUTE))
        (route1-score (get average-quality analysis1))
        (route2-score (get average-quality analysis2))
        (route1-hazards (get hazard-count analysis1))
        (route2-hazards (get hazard-count analysis2))
    )
        (ok {
            better-route: (if (and (> route1-score route2-score) (<= route1-hazards route2-hazards)) "route1" "route2"),
            route1-analysis: analysis1,
            route2-analysis: analysis2,
            quality-difference: (if (> route1-score route2-score) 
                                   (- route1-score route2-score)
                                   (- route2-score route1-score)),
            safety-comparison: (if (< route1-hazards route2-hazards) "route1-safer" 
                              (if (< route2-hazards route1-hazards) "route2-safer" "equal-safety"))
        })
    )
)
