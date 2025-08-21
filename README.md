# 🛣️ Community-Verified Road Condition Ledger

A decentralized road condition reporting system built on Stacks blockchain where drivers can submit road reports, verify each other's submissions, and earn rewards for contributing to the community.

## 🚀 Features

- **📝 Report Submission**: Drivers can submit detailed road condition reports with location coordinates
- **✅ Community Verification**: Other users can verify reports through a stake-based voting system  
- **💰 Rewards System**: Contributors earn STX rewards for verified reports and successful verifications
- **📊 Reputation Tracking**: Users build reputation scores based on their contributions
- **⏰ Time-based Expiry**: Reports expire after 144 blocks to ensure data freshness
- **🎯 Location Mapping**: Track multiple reports per location with historical data

## 🔧 Smart Contract Functions

### Public Functions

#### `submit-report`
Submit a new road condition report
```clarity
(submit-report latitude longitude condition severity description)
```
- **Parameters**:
  - `latitude` (int): GPS latitude coordinate
  - `longitude` (int): GPS longitude coordinate  
  - `condition` (string-ascii 20): Road condition type (e.g., "pothole", "construction")
  - `severity` (uint): Severity level 1-10
  - `description` (string-utf8 256): Detailed description
- **Stake Required**: 1 STX for high severity (8-10), 0.5 STX for lower severity

#### `verify-report`  
Verify an existing report
```clarity
(verify-report report-id vote)
```
- **Parameters**:
  - `report-id` (uint): ID of report to verify
  - `vote` (bool): true for valid, false for invalid
- **Stake Required**: 1 STX for positive votes, 0.5 STX for negative votes

#### `claim-verification-rewards`
Claim rewards for successful verifications
```clarity
(claim-verification-rewards report-id)
```

### Read-Only Functions

#### `get-report`
Retrieve report details by ID
```clarity
(get-report report-id)
```

#### `get-user-stats`  
Get user statistics and reputation
```clarity
(get-user-stats user-principal)
```

#### `get-location-reports`
Get report summary for a specific location
```clarity
(get-location-reports latitude longitude)
```

#### `get-total-reports`
Get total number of reports submitted

#### `get-total-verified-reports` 
Get total number of verified reports

## 💎 Reward Structure

- **Report Verification**: 0.5 STX for verified reports
- **Successful Verification**: 0.16 STX for correct verification votes
- **Reputation Points**:
  - Submit report: +10 points
  - Verified report: +50 points  
  - Successful verification: +5 points

## 🏗️ Setup & Deployment

1. **Prerequisites**
   ```bash
   npm install -g @stacks/cli
   ```

2. **Deploy Contract**
   ```bash
   clarinet deploy --testnet
   ```

3. **Run Tests**
   ```bash
   clarinet test
   ```

## 📱 Usage Examples

### Submit a Road Report
```javascript
// Example: Report a pothole
const result = await callPublicFunction({
  contractAddress: 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM',
  contractName: 'community-verified-road-condition',
  functionName: 'submit-report',
  functionArgs: [
    intCV(4012345),     // latitude
    intCV(-7412345),    // longitude  
    stringAsciiCV('pothole'),
    uintCV(8),          // severity
    stringUtf8CV('Large pothole blocking right lane')
  ],
  senderKey: privateKey,
});
```

### Verify a Report
```javascript
const verification = await callPublicFunction({
  contractAddress: 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM',
  contractName: 'community-verified-road-condition', 
  functionName: 'verify-report',
  functionArgs: [
    uintCV(1),          // report ID
    trueCV()            // vote: true = valid report
  ],
  senderKey: privateKey,
});
```

## 🔒 Security Features

- **Stake-based Verification**: Users must stake STX to participate
- **Time Expiry**: Reports expire after 144 blocks (≈24 hours)
- **Reputation System**: Tracks user reliability over time
- **Multiple Verification**: Requires 3+ verifications before finalization
- **Emergency Pause**: Contract owner can pause in emergencies

## 🌟 Roadmap

- [ ] Mobile app integration
- [ ] Photo/video attachments via IPFS
- [ ] Government agency integration
- [ ] Real-time notifications
- [ ] Advanced analytics dashboard

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details

---

**Built with ❤️ for safer roads** 🚗💨
