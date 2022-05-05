//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.4/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.4/interfaces/LinkTokenInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract LigoRentalAgreement is ChainlinkClient, Ownable {    
    enum RentalAgreementStatus {PROPOSED, APPROVED, REJECTED, ACTIVE, COMPLETED, ENDED_ERROR}

    uint256 constant private LOCATION_BUFFER = 10000; //Buffer for how far from start position end position can be without incurring fine. 10000 = 1m
    uint256 constant private ODOMETER_BUFFER = 5; //Buffer for how many kilometers past agreed total kilometers allowed without incurring fine
    uint256 constant private TIME_BUFFER = 10800; //Buffer for how many seconds past agreed end time can the renter end the contrat without incurring a penalty

    uint256 constant private LOCATION_FINE = 1; //What percentage of bond goes to vehicle owner if vehicle isn't returned at the correct location + buffer, per km
    uint256 constant private ODOMETER_FINE = 1; //What percentage of bond goes to vehicle owner  if vehicle incurs more than allowed kilometers + buffer, per km
    uint256 constant private TIME_FINE = 1; //What percentage of bond goes to vehicle owner if contract ends past the agreed end date/time + buffer, per hour

    uint256 constant private PLATFORM_FEE = 1; //What percentage of the base fee goes to the Platform. To be used to fund data requests etc

    address private vehicleOwner;
    address private renter;
    uint private startDateTime; 
    uint private endDateTime;
    uint private totalRentCost; 
    uint private totalBond;
    RentalAgreementStatus private agreementStatus;

    uint private startOdometer = 0;
    uint private endOdometer = 0;
    int private startVehicleLongitude = 0; 
    int private startVehicleLatitude = 0; 
    int private endVehicleLongitude = 0; 
    int private endVehicleLatitude = 0;
    uint private rentalAgreementEndDateTime = 0;

    //variables for calulating final fee payable
    uint private totalKm = 0;
    uint private secsPastEndDate = 0;
    int private longitudeDifference = 0;
    int private latitudeDifference = 0;
    uint private totalLocationPenalty = 0;
    uint private totalOdometerPenalty = 0;
    uint private totalTimePenalty = 0;
    uint private totalPlatformFee = 0;
    uint private totalRentPayable = 0;
    uint private totalBondReturned = 0;
    uint private bondForfeited = 0;

    uint256 private oraclePaymentAmount;
    bytes32 private jobId;

    //List of events
    event rentalAgreementCreated(address vehicleOwner, address renter,uint startDateTime,uint endDateTime,uint totalRentCost, uint totalBond);
    // event contractActive(uint _startOdometer, uint _startChargeState, int _startVehicleLongitude, int _startVehicleLatitude);
    // event contractCompleted(uint _endOdometer,  uint _endChargeState, int _endVehicleLongitude, int _endVehicleLatitide);
    // event contractCompletedError(uint _endOdometer,  uint _endChargeState, int _endVehicleLongitude, int _endVehicleLatitide);
    // event agreementPayments(uint _platformFee, uint _totalRent, uint _totalBondKept, uint _totalBondForfeitted, uint _timePenality, uint _chargePenalty, uint _locationPenalty, uint _milesPenalty);
  

    /**
     * @dev Modifier to check if the vehicle owner is calling the transaction
     */
    modifier onlyVehicleOwner() {
		require(vehicleOwner == msg.sender,"Only Vehicle Owner can perform this step");
        _;
    }

    /**
     * @dev Modifier to check if the vehicle renter is calling the transaction
     */
    modifier onlyRenter() {
		require(renter == msg.sender,'Only Vehicle Renter can perform this step');
        _;
    }

    /**
     * @dev Prevents a function being run unless contract is still active
     */
    modifier onlyContractProposed() {
        require(agreementStatus == RentalAgreementStatus.PROPOSED ,'Contract must be in PROPOSED status');
        _;
    }
    
    /**
     * @dev Prevents a function being run unless contract is still active
     */
    modifier onlyContractApproved() {
        require(agreementStatus == RentalAgreementStatus.APPROVED ,'Contract must be in APPROVED status');
        _;
    }
    
    /**
     * @dev Prevents a function being run unless contract is still active
     */
    modifier onlyContractActive() {
        require(agreementStatus == RentalAgreementStatus.ACTIVE ,'Contract must be in ACTIVE status');
        _;
    }

    /**
     * @dev Step 01: Generate a contract in PROPOSED status
     */ 
     constructor(address _vehicleOwner, address _renter, uint _startDateTime, uint _endDateTime, uint _totalRentCost, uint _totalBond, 
                 address _link, address _oracle, uint256 _oraclePaymentAmount, bytes32 _jobId) public  payable onlyOwner() {
       
       //first ensure insurer has fully funded the contract - check here. money should be transferred on creation of agreement.
       require(msg.value > _totalBond, "Not enough funds sent to contract");
        
       //initialize variables required for Chainlink Node interaction
       setChainlinkToken(_link);
       setChainlinkOracle(_oracle);
       jobId = _jobId;
       oraclePaymentAmount = _oraclePaymentAmount;
        

       //now initialize values for the contract
       vehicleOwner = _vehicleOwner;
       renter = _renter;
       startDateTime = _startDateTime;
       endDateTime = _endDateTime;
       totalRentCost = _totalRentCost;
       totalBond = _totalBond;
       agreementStatus = RentalAgreementStatus.PROPOSED;
       
       emit rentalAgreementCreated(vehicleOwner,renter,startDateTime,endDateTime,totalRentCost,totalBond);
    }

    
    /**
    * @dev Step 02a: Owner ACCEPTS proposal, contract becomes APPROVED
    */ 
    function approveContract() external onlyVehicleOwner() onlyContractProposed()  {
        //Vehicle Owner simply looks at proposed agreement & either approves or denies it.
        //Only vehicle owner can run this, contract must be in PROPOSED status
        //In this case, we approve. Contract becomes Approved and sits waiting until start time reaches
        agreementStatus = RentalAgreementStatus.APPROVED;
    }
     
   /**
    * @dev Step 02b: Owner REJECTS proposal, contract becomes REJECTED. This is the end of the line for the Contract
    */ 
    function rejectContract() external onlyVehicleOwner() onlyContractProposed() {
        //Vehicle Owner simply looks at proposed agreement & either approves or denies it.
        //Only vehicle owner can run this, contract must be in PROPOSED status
        //In this case, we reject. Contract becomes Rejected. No more actions should be possible on the contract in this status
        //Return money to renter
        data = renter.transfer(address(this).balance);
        
        //return any LINK tokens in here back to the DAPP wallet
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(owner(), link.balanceOf(address(this))), "Unable to transfer");

        //Set status to rejected. This is the end of the line for this agreement
        agreementStatus = RentalAgreementStatus.REJECTED;
    }
}

// Add events