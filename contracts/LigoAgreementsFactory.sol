//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "hardhat/console.sol";

import "./LigoRentalAgreement.sol";

contract LigoAgreementsFactory is Ownable {
	enum RentalAgreementStatus {
		PROPOSED,
		APPROVED,
		REJECTED,
		ACTIVE,
		COMPLETED,
		ENDED_ERROR
	}

	// TODO find job id
	bytes32 JOB_ID = "";
	// TODO find oracle contract and node address and fee amount
	address private constant ORACLE_CONTRACT =
		0xCE83D12d9613D9b0A2beE78c221474120c606b67; // not the right one
	address private constant NODE_ADDRESS =
		0xCE83D12d9613D9b0A2beE78c221474120c606b67;
	uint256 private constant ORACLE_PAYMENT = 0;

	// Kovan network link token
	address private constant LINK_KOVAN =
		0xa36085F69e2889c224210F603D836748e7dC0088;
	// Kovan network eth-usd price feed
	address private constant ETH_USD_CONTRACT =
		0x9326BFA02ADD2366b30bacB125260Af641031331;

	enum VehicleStatus {
		PENDING,
		APPROVED
	}

	enum Currency {
		ETH,
		USD
	}

	struct Vehicle {
		string vehicleId;
		address ownerAddress;
		uint256 baseHireFee;
		uint256 bondRequired;
		Currency ownerCurrency;
		string vehicleMake;
		string vehicleModel;
		int256 vehicleLongitude;
		int256 vehicleLatitude;
		VehicleStatus status;
	}

	address[] internal keyList;

	AggregatorV3Interface internal ethUsdPriceFeed;

	mapping(address => Vehicle) public vehicles;

	LigoRentalAgreement[] public rentalAgreements;

	modifier onlyNode() {
		require(NODE_ADDRESS == msg.sender, "Only Node can call this function");
		_;
	}

	constructor() payable {
		ethUsdPriceFeed = AggregatorV3Interface(ETH_USD_CONTRACT);
	}

	event rentalAgreementCreated(
		address _newAgreement,
		uint256 _totalFundsHeld
	);

	event vehicleAdded(
		string _vehicleId,
		address _vehicleOwner,
		uint256 _baseHireFee,
		uint256 _bondRequired,
		Currency _ownerCurrency,
		string _vehicleMake,
		string _vehicleModel,
		int256 _vehicleLongitude,
		int256 _vehicleLatitude
	);

	function getLatestEthUsdPrice() public view returns (int256) {
		(, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
		return price;
	}

	function convertEthToFiat(uint256 _value, Currency _toCurrency)
		public
		view
		returns (uint256)
	{
		if (_toCurrency == Currency.ETH) {
			return _value;
		}

		uint256 ethUsdPrice = uint256(getLatestEthUsdPrice());
		uint256 inUsd = (_value * ethUsdPrice) / 1 ether;
		if (_toCurrency == Currency.USD) {
			return inUsd;
		}
		return _value;
	}

	function convertFiatToEth(uint256 _value, Currency _fromCurrency)
		public
		view
		returns (uint256)
	{
		if (_fromCurrency == Currency.ETH) {
			return _value;
		}

		uint256 ethUsdPrice = uint256(getLatestEthUsdPrice());
		uint256 fromUsd = (_value * 1 ether) / ethUsdPrice;
		if (_fromCurrency == Currency.USD) {
			return fromUsd;
		}

		return _value;
	}

	/**
	 * @dev Create a new Rental Agreement. Once it's created, all logic & flow is handled from within the LigoRentalAgreement Contract
	 */
	function newRentalAgreement(
		address _vehicleOwner,
		address _renter,
		uint256 _startDateTime,
		uint256 _endDateTime
	) public payable returns (address) {
		//vehicle owner must be different to renter
		require(_vehicleOwner != _renter, "Owner & Renter must be different");

		//start date must be < end date and must be at least 1 hour (3600 seconds)
		require(
			_endDateTime >= _startDateTime + 3600,
			"Vehicle Agreement must be for a minimum of 1 hour"
		);

		//specify agreement must be for a discrete number of hours to keep it simple
		require(
			(_endDateTime - _startDateTime) % 3600 == 0,
			"Vehicle Agreement must be for a discrete number of hours"
		);

		//vehicle to be rented must be in APPROVED status
		require(
			vehicles[_vehicleOwner].status == VehicleStatus.APPROVED,
			"Vehicle is not approved"
		);

		//ensure start date is now or in the future
		require(
			_startDateTime >= block.timestamp,
			"Vehicle Agreement cannot be in the past"
		);

		// Ensure correct amount of ETH has been sent for total rent cost & bond
		uint256 convertedMsgValue = convertEthToFiat(
			msg.value,
			vehicles[_vehicleOwner].ownerCurrency
		);
		uint256 totalRentCost = vehicles[_vehicleOwner].baseHireFee *
			((_endDateTime - _startDateTime) / 3600);
		uint256 bondRequired = vehicles[_vehicleOwner].bondRequired;

		//add 1% tolerance to account for rounding & fluctuations in case a round just ended in price feed
		require(
			convertedMsgValue + (convertedMsgValue / 100) >=
				totalRentCost + bondRequired,
			"Insufficient rent & bond paid"
		);

		// Now that we've determined the ETH passed in is correct, we need to calculate bond + fee values in ETH to send to contract
		uint256 bondRequiredETH = convertFiatToEth(
			bondRequired,
			vehicles[_vehicleOwner].ownerCurrency
		);

		// Fee value is total value minus bond. We've already validated enough ETH has been sent
		uint256 totalRentCostETH = msg.value - bondRequiredETH;

		//create new Rental Agreement
		LigoRentalAgreement rentalAgreement = new LigoRentalAgreement(
			_vehicleOwner,
			_renter,
			_startDateTime,
			_endDateTime,
			totalRentCostETH,
			bondRequiredETH,
			LINK_KOVAN,
			ORACLE_CONTRACT,
			ORACLE_PAYMENT,
			JOB_ID
		);

		// Send the ETH it owns
		payable(address(rentalAgreement)).transfer(
			totalRentCostETH + bondRequiredETH
		);

		//store new agreement in array of agreements
		rentalAgreements.push(rentalAgreement);

		emit rentalAgreementCreated(address(rentalAgreement), msg.value);

		//now that contract has been created, we need to fund it with enough LINK tokens to fulfil 1 Oracle request per day
		LinkTokenInterface link = LinkTokenInterface(
			rentalAgreement.getChainlinkToken()
		);
		link.transfer(address(rentalAgreement), 1 ether);

		return address(rentalAgreement);
	}

	/**
	 * @dev Create a new Vehicle.
	 */
	function newVehicle(
		address _vehicleOwner,
		string memory _vehicleId,
		uint256 _baseHireFee,
		uint256 _bondRequired,
		Currency _ownerCurrency,
		string memory _vehicleMake,
		string memory _vehicleModel,
		int256 _vehicleLongitude,
		int256 _vehicleLatitude
	) public {
		//adds a vehicle and stores it in the vehicles mapping. Each vehicle is represented by 1 Ethereum address

		Vehicle memory v;
		v.vehicleId = _vehicleId;
		v.ownerAddress = _vehicleOwner;
		v.baseHireFee = _baseHireFee;
		v.bondRequired = _bondRequired;
		v.ownerCurrency = _ownerCurrency;
		v.vehicleMake = _vehicleMake;
		v.vehicleModel = _vehicleModel;
		v.vehicleLongitude = _vehicleLongitude;
		v.vehicleLatitude = _vehicleLatitude;
		v.status = VehicleStatus.PENDING;

		vehicles[_vehicleOwner] = v;

		emit vehicleAdded(
			_vehicleId,
			_vehicleOwner,
			_baseHireFee,
			_bondRequired,
			_ownerCurrency,
			_vehicleMake,
			_vehicleModel,
			_vehicleLongitude,
			_vehicleLatitude
		);
	}

	/**
	 * @dev Approves a vehicle for use in the app. Only a Chainlink node can call this, as it knows if the test to the smartcar servers was
	 * successful or not
	 */
	function approveVehicle(address _walletOwner) public onlyNode {
		vehicles[_walletOwner].status = VehicleStatus.APPROVED;
		//store the key in an array where we can loop through. At this point the vehicle will be returned in searched
		keyList.push(_walletOwner);
	}

	/**
	 * @dev Return a particular Vehicle struct based on a wallet address
	 */
	function getVehicle(address _walletOwner)
		external
		view
		returns (Vehicle memory)
	{
		return vehicles[_walletOwner];
	}

	/**
	 * @dev Return all rental contract addresses
	 */
	function getRentalContracts()
		external
		view
		returns (LigoRentalAgreement[] memory)
	{
		return rentalAgreements;
	}

	/**
	 * @dev Return a particular Rental Contract based on a rental contract address
	 */
	function getRentalContract(address _rentalContract)
		external
		view
		returns (
			address,
			address,
			uint256,
			uint256,
			uint256,
			uint256,
			RentalAgreementStatus
		)
	{
		//loop through list of contracts, and find any belonging to the address
		for (uint256 i = 0; i < rentalAgreements.length; i++) {
			if (address(rentalAgreements[i]) == _rentalContract) {
				return rentalAgreements[i].getAgreementDetails();
			}
		}
	}

	/**
	 * @dev Return a list of rental contract addresses belonging to a particular vehicle owner or renter
	 *      ownerRenter = 0 means vehicle owner, 1 = vehicle renter
	 */
	function getRentalContracts(bool _isOwner, address _address)
		external
		view
		returns (address[] memory)
	{
		//loop through list of contracts, and find any belonging to the address & type (renter or vehicle owner)
		uint256 finalResultCount = 0;

		//because we need to know exact size of final memory array, first we need to iterate and count how many will be in the final result
		for (uint256 i = 0; i < rentalAgreements.length; i++) {
			if (_isOwner == true) {
				//owner scenario
				if (rentalAgreements[i].getVehicleOwner() == _address) {
					finalResultCount = finalResultCount + 1;
				}
			} else {
				//renter scenario
				if (rentalAgreements[i].getVehicleRenter() == _address) {
					finalResultCount = finalResultCount + 1;
				}
			}
		}

		//now we have the total count, we can create a memory array with the right size and then populate it
		address[] memory addresses = new address[](finalResultCount);
		uint256 addrCountInserted = 0;

		for (uint256 j = 0; j < rentalAgreements.length; j++) {
			if (_isOwner == true) {
				//owner scenario
				if (rentalAgreements[j].getVehicleOwner() == _address) {
					addresses[addrCountInserted] = address(rentalAgreements[j]);
					addrCountInserted = addrCountInserted + 1;
				}
			} else {
				//renter scenario
				if (rentalAgreements[j].getVehicleRenter() == _address) {
					addresses[addrCountInserted] = address(rentalAgreements[j]);
					addrCountInserted = addrCountInserted + 1;
				}
			}
		}

		return addresses;
	}

	/**
	 * @dev Function that takes a vehicle ID/address, start & end epochs and then searches through to see if
	 *      vehicle is available during those dates or not
	 */
	function isVehicleAvailable(
		address _ownerAddress,
		uint256 _start,
		uint256 _end
	) public view returns (bool) {
		//algorithm works as follows:
		//vehicle needs to be in approved status otherwise return false
		//loop through all rental agreemets
		//for each agreement, check if its our vehicle
		//if its our vehicle, check if agreement is approved or active (proposed & completed/error not included)
		//and if its approved or active, check if overlap:
		//overlap = param.start < contract.end && contract.start < param.end;

		if (vehicles[_ownerAddress].status == VehicleStatus.APPROVED) {
			for (uint256 i = 0; i < rentalAgreements.length; i++) {
				if (rentalAgreements[i].getVehicleOwner() == _ownerAddress) {
					LigoAgreementsFactory.RentalAgreementStatus agreementStatus = rentalAgreements[
							i
						].getAgreementStatus();
					if (
						agreementStatus ==
						LigoAgreementsFactory.RentalAgreementStatus.APPROVED ||
						agreementStatus ==
						LigoAgreementsFactory.RentalAgreementStatus.ACTIVE
					) {
						//check for overlap
						if (
							_start <
							rentalAgreements[i].getAgreementEndTime() &&
							_end > rentalAgreements[i].getAgreementStartTime()
						) {
							//overlap found, return 0
							return false;
						}
					}
				}
			}
		} else {
			//vehicle not approved, return false
			return false;
		}

		//no clashes found, we can return  success
		return true;
	}

	/**
	 * @dev Function that takes a start & end epochs and then returns all vehicle addresses that are available
	 */
	function returnAvailableVehicles(uint256 _start, uint256 _end)
		public
		view
		returns (address[] memory)
	{
		//loop through list of contracts, and find available vehicles
		uint256 finalResultCount = 0;

		//because we need to know exact size of final memory array, first we need to iterate and count how many will be in the final result
		for (uint256 i = 0; i < keyList.length; i++) {
			//call function above for each key found
			if (isVehicleAvailable(keyList[i], _start, _end) == true) {
				//vehicle is available, add to final result count
				finalResultCount = finalResultCount + 1;
			}
		}

		//now we have the total count, we can create a memory array with the right size and then populate it
		address[] memory addresses = new address[](finalResultCount);
		uint256 addrCountInserted = 0;

		for (uint256 j = 0; j < keyList.length; j++) {
			//call function above for each key found
			if (isVehicleAvailable(keyList[j], _start, _end) == true) {
				//vehicle is available, add to list
				addresses[addrCountInserted] = keyList[j];
				addrCountInserted = addrCountInserted + 1;
			}
		}

		return addresses;
	}

	/**
	 * @dev Return a list of all vehicle addresses
	 */
	function getVehicleAddresses() public view returns (address[] memory) {
		return keyList;
	}

	/**
	 * @dev Return a vehicle ID for a given vehicle address
	 */
	function getVehicleId(address _vehicleOwnerAddress)
		public
		view
		returns (string memory)
	{
		return vehicles[_vehicleOwnerAddress].vehicleId;
	}

	/**
	 * @dev Function to end provider contract, in case of bugs or needing to update logic etc, funds are returned to dapp owner, including any remaining LINK tokens
	 */
	function endContractProvider() external payable onlyOwner {
		LinkTokenInterface link = LinkTokenInterface(LINK_KOVAN);
		link.transfer(msg.sender, link.balanceOf(address(this)));
		selfdestruct(payable(owner()));
	}
}
