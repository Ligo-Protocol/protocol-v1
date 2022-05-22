// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

import "./LigoAgreementsFactory.sol";

contract LigoRentalAgreement is ChainlinkClient, Ownable {
	using Chainlink for Chainlink.Request;

	uint256 private LOCATION_BUFFER = 10; //Buffer for how far from start position end position can be without incurring fine. -> 1 = 10m -> 10 = 100m
	uint256 private ODOMETER_BUFFER = 5; //Buffer for how many kilometers allowed without incurring fine
	uint256 private TIME_BUFFER = 10800; //Buffer for how many seconds can the renter end the contrat without incurring a penalty

	uint256 private constant LOCATION_FINE = 1; //What percentage of bond goes to vehicle owner if vehicle isn't returned at the correct location + buffer, per km
	uint256 private constant ODOMETER_FINE = 1; //What percentage of bond goes to vehicle owner  if vehicle incurs more than allowed kilometers + buffer, per km
	uint256 private constant TIME_FINE = 1; //What percentage of bond goes to vehicle owner if contract ends past the agreed end date/time + buffer, per hour
	uint256 private constant PLATFORM_FEE = 1; //What percentage of the base fee goes to the Platform. To be used to fund data requests etc

	address payable private vehicleOwner;
	address payable private renter;
	string private vehicleId;
	uint256 private startDateTime;
	uint256 private endDateTime;
	uint256 private totalRentCost;
	uint256 private totalBond;
	LigoAgreementsFactory.RentalAgreementStatus private agreementStatus;

	uint256 private startOdometer = 0;
	uint256 private endOdometer = 0;
	int256 private startVehicleLongitude = 0;
	int256 private startVehicleLatitude = 0;
	int256 private endVehicleLongitude = 0;
	int256 private endVehicleLatitude = 0;

	//variables for calulating final fee payable
	uint256 private totalLocationPenalty = 0;
	uint256 private totalOdometerPenalty = 0;
	uint256 private totalTimePenalty = 0;
	uint256 private totalPlatformFee = 0;
	uint256 private totalRentPayable = 0;
	uint256 private totalBondReturned = 0;
	uint256 private bondForfeited = 0;

	bytes32 private JOB_ID;
	uint256 private ORACLE_PAYMENT;

	//List of events
	event rentalAgreementCreated(
		address _vehicleOwner,
		address _renter,
		string _vehicleId,
		uint256 _startDateTime,
		uint256 _endDateTime,
		uint256 _totalRentCost,
		uint256 _totalBond
	);
	event contractActive(
		uint256 _startOdometer,
		int256 _startVehicleLongitude,
		int256 _startVehicleLatitude
	);
	event contractCompleted(
		uint256 _endOdometer,
		int256 _endVehicleLongitude,
		int256 _endVehicleLatitide
	);
	event agreementPayments(
		uint256 _platformFee,
		uint256 _totalRent,
		uint256 _totalBondReturned,
		uint256 _totalBondForfeitted,
		uint256 _timePenality,
		uint256 _locationPenalty,
		uint256 _kmPenalty
	);

	/**
	 * @dev Modifier to check if the vehicle owner is calling the transaction
	 */
	modifier onlyVehicleOwner() {
		require(
			vehicleOwner == msg.sender,
			"Only Vehicle Owner can perform this step"
		);
		_;
	}

	/**
	 * @dev Modifier to check if the vehicle renter is calling the transaction
	 */
	modifier onlyRenter() {
		require(
			renter == msg.sender,
			"Only Vehicle Renter can perform this step"
		);
		_;
	}

	/**
	 * @dev Prevents a function being run unless contract is still active
	 */
	modifier onlyContractProposed() {
		require(
			agreementStatus ==
				LigoAgreementsFactory.RentalAgreementStatus.PROPOSED,
			"Contract must be in PROPOSED status"
		);
		_;
	}

	/**
	 * @dev Prevents a function being run unless contract is still active
	 */
	modifier onlyContractApproved() {
		require(
			agreementStatus ==
				LigoAgreementsFactory.RentalAgreementStatus.APPROVED,
			"Contract must be in APPROVED status"
		);
		_;
	}

	/**
	 * @dev Prevents a function being run unless contract is still active
	 */
	modifier onlyContractActive() {
		require(
			agreementStatus ==
				LigoAgreementsFactory.RentalAgreementStatus.ACTIVE,
			"Contract must be in ACTIVE status"
		);
		_;
	}

	/**
	 * @dev Step 01: Generate a contract in PROPOSED status
	 */
	constructor(LigoAgreementsFactory.Agreement memory _agreementDetails)
		payable
	{
		require(
			msg.value >=
				_agreementDetails.totalRentCost +
					_agreementDetails.bondRequired,
			"Insufficient rent & bond paid"
		);

		// initialize variables required for Chainlink Node interaction
		setChainlinkToken(_agreementDetails.linkToken);
		setChainlinkOracle(_agreementDetails.oracleContract);

		JOB_ID = _agreementDetails.jobId;
		ORACLE_PAYMENT = _agreementDetails.oraclePayment;

		// set the buffers for agreement details
		// now initialize values for the contract
		vehicleOwner = payable(_agreementDetails.vehicleOwner);
		renter = payable(_agreementDetails.renter);
		vehicleId = _agreementDetails.vehicleId;
		startDateTime = _agreementDetails.startDateTime;
		endDateTime = _agreementDetails.endDateTime;
		totalRentCost = _agreementDetails.totalRentCost;
		totalBond = _agreementDetails.bondRequired;

		agreementStatus = LigoAgreementsFactory.RentalAgreementStatus.PROPOSED;
		emit rentalAgreementCreated(
			_agreementDetails.vehicleOwner,
			_agreementDetails.renter,
			_agreementDetails.vehicleId,
			_agreementDetails.startDateTime,
			_agreementDetails.endDateTime,
			_agreementDetails.totalRentCost,
			_agreementDetails.bondRequired
		);
	}

	/**
	 * @dev Step 02a: Owner ACCEPTS proposal, contract becomes APPROVED
	 */
	function approveContract() external onlyVehicleOwner onlyContractProposed {
		//Vehicle Owner simply looks at proposed agreement & either approves or denies it.
		//Only vehicle owner can run this, contract must be in PROPOSED status
		//In this case, we approve. Contract becomes Approved and sits waiting until start time reaches
		agreementStatus = LigoAgreementsFactory.RentalAgreementStatus.APPROVED;
	}

	/**
	 * @dev Step 02b: Owner REJECTS proposal, contract becomes REJECTED. This is the end of the line for the Contract
	 */
	function rejectContract()
		external
		payable
		onlyVehicleOwner
		onlyContractProposed
	{
		//Vehicle Owner simply looks at proposed agreement & either approves or denies it.
		//Only vehicle owner can run this, contract must be in PROPOSED status
		//In this case, we reject. Contract becomes Rejected. No more actions should be possible on the contract in this status
		//Return money to renter
		renter.transfer(address(this).balance);

		//return any LINK tokens in here back to the DAPP wallet
		LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
		link.transfer(owner(), link.balanceOf(address(this)));

		//Set status to rejected. This is the end of the line for this agreement
		agreementStatus = LigoAgreementsFactory.RentalAgreementStatus.REJECTED;
	}

	/**
	 * @dev Step 03a: Renter starts contract, contract becomes ACTIVE
	 * Conditions for starting contract: Must be APPROVED, & Start Date/Time must be <= current Date/Time
	 */
	function activateRentalContract(string memory _encToken)
		external
		onlyRenter
		onlyContractApproved
	{
		//First we need to wake up the vehicle & obtain some values needed in the contract before the vehicle can be unlocked & started
		//do external adapter call to wake up vehicle & get vehicle data

		//Need to check start time has reached
		require(
			startDateTime <= block.timestamp,
			"Start Date/Time has not been reached"
		);

		//call to chainlink node job to wake up the car, get starting vehicle data, then unlock the car
		Chainlink.Request memory req = buildChainlinkRequest(
			JOB_ID,
			address(this),
			this.activateRentalContractCallback.selector
		);
		req.add("vehicleId", vehicleId);
		req.add("encToken", _encToken);
		req.add("action", "unlock");
		sendChainlinkRequestTo(chainlinkOracleAddress(), req, ORACLE_PAYMENT);
	}

	/**
	 * @dev Step 03b: Callback function for obtaining vehicle data as part of rental agreement beginning
	 * If we get to this stage, it means the vehicle successfully returned the required data to start the agreement, & the vehicle has been unlocked
	 * Only the contract should be able to call this function
	 */
	function activateRentalContractCallback(
		bytes32 _requestId,
		uint256 _startOdometer,
		int256 _startLongitude,
		int256 _startLatitude
	) public recordChainlinkFulfillment(_requestId) {
		//Now for each one, assign the given data
		startOdometer = _startOdometer;
		startVehicleLongitude = _startLongitude;
		startVehicleLatitude = _startLatitude;

		//Values have been set, now set the contract to ACTIVE
		agreementStatus = LigoAgreementsFactory.RentalAgreementStatus.ACTIVE;

		//Emit an event now that contract is now active
		emit contractActive(
			startOdometer,
			startVehicleLongitude,
			startVehicleLatitude
		);
	}

	/**
	 * @dev Step 04a: Renter ends an active contract, contract becomes COMPLETED
	 * Conditions for ending contract: Must be ACTIVE
	 */
	function endRentalContract(string memory _encToken)
		external
		onlyRenter
		onlyContractActive
	{
		//call to chainlink node job to wake up the car, get ending vehicle data, then lock the car
		Chainlink.Request memory req = buildChainlinkRequest(
			JOB_ID,
			address(this),
			this.endRentalContractCallback.selector
		);

		req.add("vehicleId", vehicleId);
		req.add("encToken", _encToken);
		req.add("action", "lock");
		sendChainlinkRequestTo(chainlinkOracleAddress(), req, ORACLE_PAYMENT);
	}

	/**
	 * @dev Step 04b: Callback for getting vehicle data on ending a rental agreement. Based on results Contract becomes COMPELTED
	 * Conditions for ending contract: Must be ACTIVE. Only this contract should be able to call this function
	 */
	function endRentalContractCallback(
		bytes32 _requestId,
		uint256 _endOdometer,
		int256 _endLongitude,
		int256 _endLatitude
	) public recordChainlinkFulfillment(_requestId) {
		// Now for each one, assign the given data
		endOdometer = _endOdometer;
		endVehicleLongitude = _endLongitude;
		endVehicleLatitude = _endLatitude;
		//Now that we have all values in contract, we can calculate final fees & penalties payable
		//First calculate and send platform fee
		//Total to go to platform = base fee / platform fee %
		totalPlatformFee = totalRentCost / (100 / PLATFORM_FEE);
		//now total rent payable is original amount minus calculated platform fee above
		totalRentPayable = totalRentCost - totalPlatformFee;
		//Total to go to car owner = (base fee - platform fee from above) + time penalty + location penalty
		//Now calculate penalties to be used for amount to go to car owner
		//Odometer penalty. Number of kilometers over agreed total kilometers * odometer penalty per kilometer.
		//Eg if only 10 km allowed but agreement logged 20 km, with a penalty of 1% per extra km
		//then penalty is 20-10 = 10 * 1% = 10% of Bond
		uint256 totalKm = endOdometer - startOdometer;
		if (totalKm > ODOMETER_BUFFER) {
			totalOdometerPenalty =
				(totalKm - ODOMETER_BUFFER) *
				(totalBond / (100 / ODOMETER_FINE));
		}
		//Set the end time of the contract
		uint256 rentalAgreementEndDateTime = block.timestamp;
		//Time penalty. Number of hours past agreed end date/time + buffer * time penalty per hour
		//eg TIME_FINE buffer set to 1 = 1% of bond for each hour past the end date + buffer (buffer currently set to 3 hours)
		if (rentalAgreementEndDateTime > endDateTime) {
			uint256 secsPastEndDate = rentalAgreementEndDateTime - endDateTime;
			//if retuned later than the the grace period, incur penalty
			if (secsPastEndDate > TIME_BUFFER) {
				//penalty incurred
				//penalty TIME_FINE is a % per hour over. So if over by less than an hour, round up to an hour
				if (secsPastEndDate - TIME_BUFFER < 3600) {
					totalTimePenalty = totalBond / (100 / TIME_FINE);
				} else {
					//do normal penlaty calculation in hours
					totalTimePenalty =
						((secsPastEndDate - TIME_BUFFER) / 3600) *
						(totalBond / (100 / TIME_FINE));
				}
			}
		}
		//Location penalty. If the vehicle is not returned to around the same spot, then a penalty is incurred.
		//Allowed distance from original spot is stored in the LOCATION_BUFFER param, currently set to 100m
		//Penalty incurred is stored in LOCATION_FINE, and applies per km off from the original location
		//Penalty applies to either location coordinates
		//eg if LOCATION_BUFFER set to 100m, fee set to 1% per 1km, and renter returns vehicle 2km from original place
		//fee payable is 2 * 1 = 2% of bond
		uint256 longitudeDifference = abs(
			startVehicleLongitude - endVehicleLongitude
		);
		uint256 latitudeDifference = abs(
			startVehicleLatitude - endVehicleLatitude
		);
		if (longitudeDifference > LOCATION_BUFFER) {
			//If difference in longitude is > 100m
			//10000 -> 1km
			totalLocationPenalty =
				(longitudeDifference / 10000) *
				(totalBond / (100 / LOCATION_FINE));
		} else if (latitudeDifference > LOCATION_BUFFER) {
			//If difference in latitude is > 100m
			totalLocationPenalty =
				(latitudeDifference / 10000) *
				(totalBond / (100 / LOCATION_FINE));
		}
		//Final amount of bond to go to owner = sum of all penalties above. Then renter gets rest
		bondForfeited =
			totalOdometerPenalty +
			totalTimePenalty +
			totalLocationPenalty;
		//Check if forfeited bond is smaller than whole contract owned bond.
		if (bondForfeited > totalBond) {
			bondForfeited = totalBond;
			//bond returned should stay at 0;
		} else {
			totalBondReturned = totalBond - bondForfeited;
		}
		//Now that we have all fees & charges calculated, perform necessary transfers & then end contract
		//first pay platform fee
		payable(owner()).transfer(totalPlatformFee);
		//then pay vehicle owner rent amount
		uint256 totalAmoutToPayForOwner = totalRentPayable + bondForfeited;
		vehicleOwner.transfer(totalAmoutToPayForOwner);
		//finally, pay renter back any remaining bond
		if (totalBondReturned > 0) {
			renter.transfer(totalBondReturned);
		}
		//return any LINK tokens in here back to the DAPP wallet
		LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
		link.transfer(owner(), link.balanceOf(address(this)));
		//Transfers all completed, now we just need to set contract status to successfully completed
		agreementStatus = LigoAgreementsFactory.RentalAgreementStatus.COMPLETED;
		//Emit an event with all the payments
		emit agreementPayments(
			totalPlatformFee,
			totalRentPayable,
			totalBondReturned,
			bondForfeited,
			totalTimePenalty,
			totalLocationPenalty,
			totalOdometerPenalty
		);
		//Emit an event now that contract is now ended
		emit contractCompleted(
			endOdometer,
			endVehicleLongitude,
			endVehicleLatitude
		);
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
	function getAgreementStatus()
		public
		view
		returns (LigoAgreementsFactory.RentalAgreementStatus)
	{
		return agreementStatus;
	}

	/**
	 * @dev Get start date/time
	 */
	function getAgreementStartTime() public view returns (uint256) {
		return startDateTime;
	}

	/**
	 * @dev Get end date/time
	 */
	function getAgreementEndTime() public view returns (uint256) {
		return endDateTime;
	}

	/**
	 * @dev Return All Details about a Vehicle Rental Agreement
	 */
	function getAgreementDetails()
		public
		view
		returns (
			address,
			address,
			uint256,
			uint256,
			uint256,
			uint256,
			LigoAgreementsFactory.RentalAgreementStatus
		)
	{
		return (
			vehicleOwner,
			renter,
			startDateTime,
			endDateTime,
			totalRentCost,
			totalBond,
			agreementStatus
		);
	}

	/**
	 * @dev Return All Vehicle Data from a Vehicle Rental Agreement
	 */
	function getAgreementData()
		public
		view
		returns (
			uint256,
			int256,
			int256,
			uint256,
			int256,
			int256
		)
	{
		return (
			startOdometer,
			startVehicleLongitude,
			startVehicleLatitude,
			endOdometer,
			endVehicleLongitude,
			endVehicleLatitude
		);
	}

	/**
	 * @dev Return All Payment & fee Details about a Vehicle Rental Agreement
	 */
	function getPaymentDetails()
		public
		view
		returns (
			uint256,
			uint256,
			uint256,
			uint256,
			uint256,
			uint256
		)
	{
		return (
			totalLocationPenalty,
			totalOdometerPenalty,
			totalTimePenalty,
			totalPlatformFee,
			totalRentPayable,
			totalBondReturned
		);
	}

	/**
	 * @dev Helper function to get absolute value of an int
	 */
	function abs(int256 x) private pure returns (uint256) {
		return x >= 0 ? uint256(x) : uint256(-x);
	}
}
