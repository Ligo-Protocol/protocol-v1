//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
pragma experimental ABIEncoderV2;


import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LigoAgreementsFactory.sol";
import "hardhat/console.sol";

contract LigoRentalAgreement is ChainlinkClient, Ownable {   
    using Chainlink for Chainlink.Request;
     
    enum RentalAgreementStatus {PROPOSED, APPROVED, REJECTED, ACTIVE, COMPLETED, ENDED_ERROR}

    uint256 constant private LOCATION_BUFFER = 10000; //Buffer for how far from start position end position can be without incurring fine. 10000 = 1m
    uint256 constant private ODOMETER_BUFFER = 5; //Buffer for how many kilometers past agreed total kilometers allowed without incurring fine
    uint256 constant private TIME_BUFFER = 10800; //Buffer for how many seconds past agreed end time can the renter end the contrat without incurring a penalty

    uint256 constant private LOCATION_FINE = 1; //What percentage of bond goes to vehicle owner if vehicle isn't returned at the correct location + buffer, per km
    uint256 constant private ODOMETER_FINE = 1; //What percentage of bond goes to vehicle owner  if vehicle incurs more than allowed kilometers + buffer, per km
    uint256 constant private TIME_FINE = 1; //What percentage of bond goes to vehicle owner if contract ends past the agreed end date/time + buffer, per hour

    uint256 constant private PLATFORM_FEE = 1; //What percentage of the base fee goes to the Platform. To be used to fund data requests etc

    address payable private vehicleOwner;
    address payable private renter;
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
    event rentalAgreementCreated(address _vehicleOwner, address _renter, uint _startDateTime, uint _endDateTime, uint _totalRentCost, uint _totalBond);
    event contractActive(uint _startOdometer, uint _startChargeState, int _startVehicleLongitude, int _startVehicleLatitude);
    event contractCompleted(uint _endOdometer,  uint _endChargeState, int _endVehicleLongitude, int _endVehicleLatitide);
    event contractCompletedError(uint _endOdometer,  uint _endChargeState, int _endVehicleLongitude, int _endVehicleLatitide);
    event agreementPayments(uint _platformFee, uint _totalRent, uint _totalBondKept, uint _totalBondForfeitted, uint _timePenality, uint _chargePenalty, uint _locationPenalty, uint _milesPenalty);
  

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
                address _link, address _oracle, uint256 _oraclePaymentAmount, bytes32 _jobId) payable onlyOwner() {
    
        //first ensure insurer has fully funded the contract - check here. money should be transferred on creation of agreement.
        require(msg.value > _totalBond, "Not enough funds sent to contract");
        
        //initialize variables required for Chainlink Node interaction
        setChainlinkToken(_link);
        setChainlinkOracle(_oracle);
        jobId = _jobId;
        oraclePaymentAmount = _oraclePaymentAmount;
        

        //now initialize values for the contract
        vehicleOwner = payable(_vehicleOwner);
        renter = payable(_renter);
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
        renter.transfer(address(this).balance);
        
        //return any LINK tokens in here back to the DAPP wallet
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(owner(), link.balanceOf(address(this))), "Unable to transfer");

        //Set status to rejected. This is the end of the line for this agreement
        agreementStatus = RentalAgreementStatus.REJECTED;
    }

    /**
    * @dev Step 03a: Renter starts contract, contract becomes ACTIVE
    * Conditions for starting contract: Must be APPROVED, & Start Date/Time must be <= current Date/Time
    */ 
    function activateRentalContract(string memory _encToken) external onlyRenter() onlyContractApproved() {
        //First we need to wake up the vehicle & obtain some values needed in the contract before the vehicle can be unlocked & started
        //do external adapter call to wake up vehicle & get vehicle data
        
        //Need to check start time has reached
        require(startDateTime <= block.timestamp ,'Start Date/Time has not been reached');
        
        //get vehicle ID of the vehicle, needed for the request
        uint vid = LigoAgreementsFactory(owner()).getVehicleId(vehicleOwner);
        
        //call to chainlink node job to wake up the car, get starting vehicle data, then unlock the car
        Chainlink.Request memory req = buildChainlinkRequest(jobId, address(this), this.activateRentalContractCallback.selector);
        req.add("vehicleId", Strings.toString(vid));
        req.add("encToken", _encToken);
        req.add("action", "unlock");
        sendChainlinkRequestTo(chainlinkOracleAddress(), req, oraclePaymentAmount);
        
    }
     
    /**
    * @dev Step 03b: Callback function for obtaining vehicle data as part of rental agreement beginning
    * If we get to this stage, it means the vehicle successfully returned the required data to start the agreement, & the vehicle has been unlocked
    * Only the contract should be able to call this function
    */ 
    function activateRentalContractCallback(bytes32 _requestId, bytes32 _vehicleData) public recordChainlinkFulfillment(_requestId) {
        // //Set contract variables to start the agreement
        
        // //temp variables required for converting to signed integer
        // bytes memory longitudeBytes;
        // bytes memory latitudeBytes;                           
        
        // //Now for each one, convert to uint
        // startOdometer = stringToUint(splitResults[0]);
        // startChargeState = stringToUint(splitResults[1]);

        // //Now store location coordinates in signed variables. Will always be positive, but will check in the next step if need to make negative
        // startVehicleLongitude =  int(stringToUint(splitResults[2]));
        // startVehicleLatitude =  int(stringToUint(splitResults[3]));

        // //Finally, check first bye in the string for the location variables. If it was a '-', then multiply location coordinate by -1
        // //first get the first byte of each location coordinate string
        // longitudeBytes = bytes(splitResults[2]);
        // latitudeBytes = bytes(splitResults[3]);
        
        
        // //First check longitude
        // if (uint(longitudeBytes[0]) == 0x2d) {
        //     //first byte was a '-', multiply result by -1
        //     startVehicleLongitude = startVehicleLongitude * -1;
        // }
        
        // //Now check latitude
        // if (uint(latitudeBytes[0]) == 0x2d) {
        //     //first byte was a '-', multiply result by -1
        //     startVehicleLatitude = startVehicleLatitude * -1;
        // }
        

        // //Values have been set, now set the contract to ACTIVE
        // agreementStatus = RentalAgreementStatus.ACTIVE;
        
        // //Emit an event now that contract is now active
        // // emit contractActive(startOdometer,startChargeState,startVehicleLongitude,startVehicleLatitude);
    }


   /**
    * @dev Step 04a: Renter ends an active contract, contract becomes COMPLETED or ENDED_ERROR
    * Conditions for ending contract: Must be ACTIVE
    */ 
    function endRentalContract(string memory _encToken) external onlyRenter() onlyContractActive()  {
        //First we need to check if vehicle can be accessed, if so then do a call to get vehicle data

        //get vehicle ID of the vehicle, needed for the request
        uint vid = LigoAgreementsFactory(owner()).getVehicleId(vehicleOwner);
        
        //call to chainlink node job to wake up the car, get ending vehicle data, then lock the car
        Chainlink.Request memory req = buildChainlinkRequest(jobId, address(this), this.endRentalContractCallback.selector);
        req.add("vehicleId", Strings.toString(vid));
        req.add("encToken", _encToken);
        req.add("action", "lock");
        sendChainlinkRequestTo(chainlinkOracleAddress(), req, oraclePaymentAmount);
    }

   /**
    * @dev Step 04b: Callback for getting vehicle data on ending a rental agreement. Based on results Contract becomes COMPELTED or ENDED_ERROR
    * Conditions for ending contract: Must be ACTIVE. Only this contract should be able to call this function
    */ 
    function endRentalContractCallback(bytes32 _requestId, bytes32 _vehicleData) public recordChainlinkFulfillment(_requestId) {
        // //Set contract variables to end the agreement
        
        // //temp variables required for converting to signed integer
        // uint tmpEndLongitude;
        // uint tmpEndLatitude;
        // bytes memory longitudeBytes;
        // bytes memory latitudeBytes;
        
        
        // //first split the results into individual strings based on the delimiter
        // var s = bytes32ToString(_vehicleData).toSlice();
        // var delim = ",".toSlice();
        
        // //store each string in an array
        // string[] memory splitResults = new string[](s.count(delim)+ 1);                  
        // for (uint i = 0; i < splitResults.length; i++) {                              
        //     splitResults[i] = s.split(delim).toString();                              
        // }                                                        
        
        // //Now for each one, convert to uint
        // endOdometer = stringToUint(splitResults[0]);
        // endChargeState = stringToUint(splitResults[1]);
        // tmpEndLongitude = stringToUint(splitResults[2]);
        // tmpEndLatitude = stringToUint(splitResults[3]);
        
        // //Now store location coordinates in signed variables. Will always be positive, but will check in the next step if need to make negative
        // endVehicleLongitude =  int(tmpEndLongitude);
        // endVehicleLatitude =  int(tmpEndLatitude);

        // //Finally, check first bye in the string for the location variables. If it was a '-', then multiply location coordinate by -1
        // //first get the first byte of each location coordinate string
        // longitudeBytes = bytes(splitResults[2]);
        // latitudeBytes = bytes(splitResults[3]);
        
        
        // //First check longitude
        // if (uint(longitudeBytes[0]) == 0x2d) {
        //     //first byte was a '-', multiply result by -1
        //     endVehicleLongitude = endVehicleLongitude * -1;
        // }
        
        // //Now check latitude
        // if (uint(latitudeBytes[0]) == 0x2d) {
        //     //first byte was a '-', multiply result by -1
        //     endVehicleLatitude = endVehicleLatitude * -1;
        // }
        
        // //Set the end time of the contract
        // rentalAgreementEndDateTime = now;
        

        // //Now that we have all values in contract, we can calculate final fees & penalties payable
        
        // //First calculate and send platform fee 
        // //Total to go to platform = base fee / platform fee %
        // totalPlatformFee = totalRentCost.div(uint(100).div(PLATFORM_FEE));
        
        // //now total rent payable is original amount minus calculated platform fee above
        // totalRentPayable = totalRentCost - totalPlatformFee;
        
        // //Total to go to car owner = (base fee - platform fee from above) + time penalty + location penalty + charge penalty
        
        // //Now calculate penalties to be used for amount to go to car owner
        
        // //Odometer penalty. Number of miles over agreed total miles * odometer penalty per mile.
        // //Eg if only 10 miles allowed but agreement logged 20 miles, with a penalty of 1% per extra mile
        // //then penalty is 20-10 = 10 * 1% = 10% of Bond
        // totalMiles = endOdometer.sub(startOdometer);
        // if (totalMiles > ODOMETER_BUFFER) { 
        
        //     totalOdometerPenalty = totalMiles.mul(ODOMETER_FINE).mul(totalBond);  
        //     totalOdometerPenalty = (totalMiles.sub(ODOMETER_BUFFER)).mul(totalBond.div(uint(100).div(ODOMETER_FINE)));
        // }
        
        // //Time penalty. Number of hours past agreed end date/time + buffer * time penalty per hour
        // //eg TIME_FINE buffer set to 1 = 1% of bond for each hour past the end date + buffer (buffer currently set to 3 hours)
        // if (rentalAgreementEndDateTime > endDateTime) {
        //         secsPastEndDate = rentalAgreementEndDateTime.sub(endDateTime);
        //         //if retuned later than the the grace period, incur penalty
        //     if (secsPastEndDate > TIME_BUFFER) { //penalty incurred
        //         //penalty TIME_FINE is a % per hour over. So if over by less than an hour, round up to an hour
        //         if (secsPastEndDate.sub(TIME_BUFFER) < 3600) {
        //             totalTimePenalty = uint(1).mul(totalBond.div(uint(100).div(TIME_FINE)));
        //         } else {
        //             //do normal penlaty calculation in hours
        //             totalTimePenalty = secsPastEndDate.sub(TIME_BUFFER).div(3600).mul(totalBond.div(uint(100).div(TIME_FINE)));
        //         }
        //     }
        // }
        
        // //Charge penalty. Simple comparison of charge at start & end. If it isn't at least what it was at agreement start, then a static fee is paid of
        // //CHARGE_FINE, which is a % of bond. Currently set to 1%
        // if (startChargeState > endChargeState) { 
        //     totalChargePenalty = totalBond.div(uint(100).div(CHARGE_FINE));
        // }
        
        

        // //Location penalty. If the vehicle is not returned to around the same spot, then a penalty is incurred.
        // //Allowed distance from original spot is stored in the LOCATION_BUFFER param, currently set to 100m
        // //Penalty incurred is stored in LOCATION_FINE, and applies per km off from the original location
        // //Penalty applies to either location coordinates
        // //eg if LOCATION_BUFFER set to 100m, fee set to 1% per 1km, and renter returns vehicle 2km from original place
        // //fee payable is 2 * 1 = 2% of bond
        
        
        // longitudeDifference = abs(abs(startVehicleLongitude) - abs(endVehicleLongitude));
        // latitudeDifference = abs(abs(startVehicleLatitude) - abs(endVehicleLatitude));

        
        // if (longitudeDifference > LOCATION_BUFFER) { //If difference in longitude is > 100m
        //     totalLocationPenalty = uint(longitudeDifference).div(10000).mul(totalBond.div(uint(100).div(LOCATION_FINE))); 
        // } else  if (latitudeDifference > LOCATION_BUFFER) { //If difference in latitude is > 100m
        //     totalLocationPenalty = uint(latitudeDifference).div(10000).mul(totalBond.div(uint(100).div(LOCATION_FINE)));
        // } 

        
        // //Final amount of bond to go to owner = sum of all penalties above. Then renter gets rest
        // bondForfeited = totalOdometerPenalty.add(totalTimePenalty).add(totalChargePenalty).add(totalLocationPenalty);
        // uint bondKept = totalBond.sub(bondForfeited);

        
        // //Now that we have all fees & charges calculated, perform necessary transfers & then end contract
        // //first pay platform fee
        // dappWallet.transfer(totalPlatformFee);
        
        // //then pay vehicle owner rent amount
        // vehicleOwner.transfer(totalRentPayable);
        
        // //pay Owner  any bond penalties. Only if > 0
        // if (bondForfeited > 0) {
        //     owner.transfer(bondForfeited);
        // }
        
        // //finally, pay renter back any remaining bond
        // totalBondReturned = address(this).balance;
        // renter.transfer(totalBondReturned);
        
        // //Transfers all completed, now we just need to set contract status to successfully completed 
        // agreementStatus = RentalAgreementFactory.RentalAgreementStatus.COMPLETED;
        
        // //Emit an event with all the payments
        // emit agreementPayments(totalPlatformFee, totalRentPayable, bondKept, bondForfeited, totalTimePenalty, totalChargePenalty, totalLocationPenalty, totalOdometerPenalty);
            
            
        // //Emit an event now that contract is now ended
        // emit contractCompleted(endOdometer,endChargeState,endVehicleLongitude,endVehicleLatitude);
    }
  
   /**
    * @dev Step 04c: Car Owner ends an active contract due to the Renter not ending it, contract becomes ENDED_ERROR
    * Conditions for ending contract: Must be ACTIVE, & End Date must be in the past more than the current defined TIME_BUFFER value
    */ 
    function forceEndRentalContract(string memory _encToken) external onlyOwner() onlyContractActive() {
        
        //don't allow unless contract still active & current time is > contract end date + TIME_BUFFER
        require(block.timestamp > endDateTime + TIME_BUFFER,
                "Agreement not eligible for forced cancellation yet");
                
        //get vehicle ID of the vehicle, needed for the request
        uint vid = LigoAgreementsFactory(owner()).getVehicleId(vehicleOwner);
        
        //call to chainlink node job to wake up the car, get ending vehicle data
        Chainlink.Request memory req = buildChainlinkRequest(jobId, address(this), this.forceEndRentalContractCallback.selector);
        req.add("vehicleId", Strings.toString(vid));
        req.add("encToken", _encToken);
        req.add("action", "vehicle_data");
        sendChainlinkRequestTo(chainlinkOracleAddress(), req, oraclePaymentAmount);
    }
    
   /**
    * @dev Step 04d: Callback for force ending a vehicle agreement. Based on results Contract becomes ENDED_ERROR
    */ 
    function forceEndRentalContractCallback(bytes32 _requestId, bytes32 _vehicleData) public recordChainlinkFulfillment(_requestId) {
        // totalPlatformFee = totalRentCost.div(uint(100).div(PLATFORM_FEE));

        // //now total rent payable is original amount minus calculated platform fee above
        // totalRentPayable = totalRentCost - totalPlatformFee;
        
        // bondForfeited = totalBondReturned;
        // totalBondReturned = 0;
        
        
        // //Now that we have all fees & charges calculated, perform necessary transfers & then end contract
        // //first pay platform fee
        // dappWallet.transfer(totalPlatformFee);
        
        // //then pay vehicle owner rent payable
        // vehicleOwner.transfer(totalRentPayable);
        
        // //pay owner the bond owed
        // vehicleOwner.transfer(bondForfeited);
        

        // //Transfers all completed, now we just need to set contract status to successfully completed 
        // agreementStatus = RentalAgreementFactory.RentalAgreementStatus.ENDED_ERROR;
        
        // //Emit an event now that contract is now ended
        // emit contractCompletedError(endOdometer,endChargeState,endVehicleLongitude,endVehicleLatitude);
            
    }
    
        /**
     * @dev Get address of the chainlink token
     */ 
    function getChainlinkToken() public view returns (address) {
        return chainlinkTokenAddress();
    }
    
    /**
     * @dev Get address of vehicle owner
     */ 
    function getVehicleOwner() public view returns (address) {
        return vehicleOwner;
    }
    
    /**
     * @dev Get address of vehicle renter
     */ 
    function getVehicleRenter() public view returns (address) {
        return renter;
    }
    
    /**
     * @dev Get status of the agreement
     */ 
    function getAgreementStatus() public view returns (RentalAgreementStatus) {
        return agreementStatus;
    }
    
    /**
     * @dev Get start date/time
     */ 
    function getAgreementStartTime() public view returns (uint) {
        return startDateTime;
    }
    
    /**
     * @dev Get end date/time
     */ 
    function getAgreementEndTime() public view returns (uint) {
        return endDateTime;
    }
    

    /**
     * @dev Return All Details about a Vehicle Rental Agreement
     */ 
    function getAgreementDetails() public view returns (address,address,uint,uint,uint,uint,RentalAgreementStatus) {
        return (vehicleOwner,renter,startDateTime,endDateTime,totalRentCost,totalBond,agreementStatus);
    }
    
    /**
     * @dev Return All Vehicle Data from a Vehicle Rental Agreement
     */ 
    function getAgreementData() public view returns (uint, int, int, uint, int, int) {
        return (startOdometer, startVehicleLongitude, startVehicleLatitude,endOdometer, endVehicleLongitude,endVehicleLatitude);
    }
    
    /**
     * @dev Return All Payment & fee Details about a Vehicle Rental Agreement
     */ 
    function getPaymentDetails() public view returns (uint, uint, uint, uint, uint, uint, uint) {
        return (rentalAgreementEndDateTime,totalLocationPenalty,totalOdometerPenalty,totalTimePenalty,totalPlatformFee,totalRentPayable,totalBondReturned);
    }
    
    /**
     * @dev Helper function to get absolute value of an int
     */ 
    function abs(int x) private pure returns (int) {
        return x >= 0 ? x : -x;
    }

}

// Add events