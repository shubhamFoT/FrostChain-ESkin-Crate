// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract FrostChainQualitySettlement {
    address public buyerArbiter;
    address public farmerBeneficiary;
    address public crateOracleDevice;

    uint256 public baseContractPayoutWei;
    int256  public constant TARGET_TEMP_X10 = 40; // 4.0 degC (x10)
    int256  public constant UPPER_BAND_X10  = 60; // 6.0 degC upper band

    enum SettlementStatus { InTransit, SettledFull_100, SettledTier2_80, SettledSalvage_50, FrozenTamperReview }
    SettlementStatus public currentStatus;

    struct CrateTelemetryRecord {
        uint256 timestamp;
        int256  crateTempX10;
        uint256 durationMinutes;
        uint256 reversibleShockCnt;
        uint256 cleanStrainUe;
        bool    tamperStepFlag;
        bool    sensorFaultFlag;
    }

    CrateTelemetryRecord[] public transitLog;
    uint256 public finalQualityScore = 100;
    bool    public tamperEscrowHold  = false;

    event TelemetryAnchored(uint256 indexed index, int256 tempX10, uint256 strainUe, bool tamper, bool fault);
    event PayoutSettled(SettlementStatus status, uint256 qualityScore, uint256 payoutAmountWei);

    modifier onlyOracle() {
        require(msg.sender == crateOracleDevice || msg.sender == buyerArbiter, 'Unauthorized oracle');
        _;
    }

    constructor(address _farmer, address _oracle) payable {
        buyerArbiter = msg.sender;
        farmerBeneficiary = _farmer;
        crateOracleDevice = _oracle;
        baseContractPayoutWei = msg.value;
        currentStatus = SettlementStatus.InTransit;
    }

    function pushSignedCrateEvent(
        int256  _crateTempX10,
        uint256 _durationMinutes,
        uint256 _reversibleShockCnt,
        uint256 _cleanStrainUe,
        bool    _tamperStepFlag,
        bool    _sensorFaultFlag
    ) external onlyOracle {
        require(currentStatus == SettlementStatus.InTransit || currentStatus == SettlementStatus.FrozenTamperReview, 'Already settled');
        transitLog.push(CrateTelemetryRecord(block.timestamp, _crateTempX10, _durationMinutes, _reversibleShockCnt, _cleanStrainUe, _tamperStepFlag, _sensorFaultFlag));
        if (_tamperStepFlag && !_sensorFaultFlag) {
            tamperEscrowHold = true;
            currentStatus = SettlementStatus.FrozenTamperReview;
        }
        emit TelemetryAnchored(transitLog.length - 1, _crateTempX10, _cleanStrainUe, _tamperStepFlag, _sensorFaultFlag);
    }

    function computeQualityScoreAndSettle() external returns (uint256 score, SettlementStatus status) {
        require(currentStatus == SettlementStatus.InTransit || currentStatus == SettlementStatus.FrozenTamperReview, 'Already settled');
        uint256 accumulatedDegreeMinutesX10 = 0;
        uint256 handlingPenalty = 0;
        for (uint256 i = 0; i < transitLog.length; i++) {
            CrateTelemetryRecord memory rec = transitLog[i];
            if (rec.crateTempX10 > UPPER_BAND_X10) {
                uint256 deltaTX10 = uint256(rec.crateTempX10 - TARGET_TEMP_X10);
                accumulatedDegreeMinutesX10 += (deltaTX10 * rec.durationMinutes);
            }
            handlingPenalty += (rec.reversibleShockCnt * 2);
        }
        uint256 thermalPenalty = (accumulatedDegreeMinutesX10 + 300) / 600;
        uint256 totalDeduction = thermalPenalty + handlingPenalty;
        finalQualityScore = (totalDeduction >= 100) ? 0 : (100 - totalDeduction);

        if (tamperEscrowHold) {
            currentStatus = SettlementStatus.FrozenTamperReview;
            emit PayoutSettled(SettlementStatus.FrozenTamperReview, finalQualityScore, 0);
            return (finalQualityScore, SettlementStatus.FrozenTamperReview);
        }
        uint256 payoutWei = 0;
        if (finalQualityScore > 90) {
            payoutWei = baseContractPayoutWei;
            currentStatus = SettlementStatus.SettledFull_100;
        } else if (finalQualityScore >= 70) {
            payoutWei = (baseContractPayoutWei * 80) / 100;
            currentStatus = SettlementStatus.SettledTier2_80;
        } else {
            payoutWei = (baseContractPayoutWei * 50) / 100;
            currentStatus = SettlementStatus.SettledSalvage_50;
        }
        if (payoutWei > 0 && address(this).balance >= payoutWei) {
            (bool ok, ) = payable(farmerBeneficiary).call{value: payoutWei}('');
            require(ok, 'Transfer failed');
        }
        emit PayoutSettled(currentStatus, finalQualityScore, payoutWei);
        return (finalQualityScore, currentStatus);
    }
}
