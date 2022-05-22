//SPDX-License-Identifier: MITKOVAN
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

import "./LigoRentalAgreement.sol";

contract LigoAgreementsFactory is Ownable {
	bytes32 private JOB_ID; // "65f26cc69fe2454eacf129aef846e65a"
	address private ORACLE_CONTRACT; // 0x89dca850F3C3BF8fB0209190CD45e4a59632C73D
	uint256 private ORACLE_PAYMENT; // 100000000000000000
	address private NODE_ADDRESS; // 0xCE83D12d9613D9b0A2beE78c221474120c606b67
	address private LINK_TOKEN; // KOVAN -> 0xa36085F69e2889c224210F603D836748e7dC0088

	enum RentalAgreementStatus {
		PROPOSED,
		APPROVED,
		REJECTED,
		ACTIVE,
		COMPLETED
	}

	struct Vehicle {
		string vehicleId;
		string filecoinCid;
		address ownerAddress;
		uint256 baseHourFee;
		uint256 bondRequired;
	}

	struct Agreement {
		address vehicleOwner;
		address renter;
		string vehicleId;
		uint256 startDateTime;
		uint256 endDateTime;
		uint256 totalRentCost;
		uint256 bondRequired;
		address linkToken;
		address oracleContract;
		uint256 oraclePayment;
		bytes32 jobId;
	}

	string[] internal vehicleIds;
	mapping(string => Vehicle) internal idsToVehicles;
	mapping(address => address[]) internal ownerToAgreementsAddresses;
	mapping(address => address[]) internal renterToAgreementsAddresses;

	constructor(
		bytes32 _jobId,
		address _oracleContract,
		uint256 _oraclePayment,
		address _nodeAddress,
		address _linkToken
	) {
		JOB_ID = _jobId;
		ORACLE_CONTRACT = _oracleContract;
		ORACLE_PAYMENT = _oraclePayment;
		NODE_ADDRESS = _nodeAddress;
		LINK_TOKEN = _linkToken;
	}

	event rentalAgreementCreated(
		address _newAgreement,
		uint256 _totalFundsHeld
	);

	event vehicleAdded(
		string _vehicleId,
		string _filecoinCid,
		address _vehicleOwner,
		uint256 _baseHourFee,
		uint256 _bondRequired
	);

	/**
	 * @dev Create a new Vehicle.
	 */
	function newVehicle(
		string memory _vehicleId,
		string memory _filecoinCid,
		address _vehicleOwner,
		uint256 _baseHourFee,
		uint256 _bondRequired
	) public {
		//adds a vehicle and stores it in the vehicles mapping. Each vehicle is represented by 1 Ethereum address
		idsToVehicles[_vehicleId] = Vehicle(
			_vehicleId,
			_filecoinCid,
			_vehicleOwner,
			_baseHourFee,
			_bondRequired
		);

		vehicleIds.push(_vehicleId);

		emit vehicleAdded(
			_vehicleId,
			_filecoinCid,
			_vehicleOwner,
			_baseHourFee,
			_bondRequired
		);
	}

	/**
	 * @dev Create a new Rental Agreement. Once it's created, all logic & flow is handled from within the LigoRentalAgreement Contract
	 */
	function newRentalAgreement(
		string memory _vehicleId,
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

		//ensure start date is now or in the future
		require(
			_startDateTime >= block.timestamp,
			"Vehicle Agreement cannot be in the past"
		);

		uint256 totalRentCost = idsToVehicles[_vehicleId].baseHourFee *
			((_endDateTime - _startDateTime) / 3600);
		uint256 bondRequired = idsToVehicles[_vehicleId].bondRequired;

		// ensure the renter has deposited enough ETH
		require(
			msg.value >= totalRentCost + bondRequired,
			"Insufficient rent & bond paid"
		);

		//create new Rental Agreement and send the ETH it owns
		LigoRentalAgreement rentalAgreement = (new LigoRentalAgreement){
			value: totalRentCost + bondRequired
		}(
			Agreement(
				_vehicleOwner,
				_renter,
				_vehicleId,
				_startDateTime,
				_endDateTime,
				totalRentCost,
				bondRequired,
				LINK_TOKEN,
				ORACLE_CONTRACT,
				ORACLE_PAYMENT,
				JOB_ID
			)
		);

		//store new agreement in array of agreements
		ownerToAgreementsAddresses[_vehicleOwner].push(
			address(rentalAgreement)
		);
		renterToAgreementsAddresses[_renter].push(address(rentalAgreement));

		emit rentalAgreementCreated(
			address(rentalAgreement),
			totalRentCost + bondRequired
		);

		//now that contract has been created, we need to fund it with enough LINK tokens to fulfil 1 Oracle request per day
		LinkTokenInterface link = LinkTokenInterface(LINK_TOKEN);
		link.transfer(address(rentalAgreement), 1 ether);

		return address(rentalAgreement);
	}

	/**
	 * @dev Return a list of all vehicle ids
	 */
	function getVehicleIds() public view returns (string[] memory) {
		return vehicleIds;
	}

	/**
	 * @dev Return a particular Vehicle struct based on a its id
	 */
	function getVehicle(string memory _vehicleId)
		external
		view
		returns (
			string memory,
			string memory,
			address,
			uint256,
			uint256
		)
	{
		Vehicle memory v = idsToVehicles[_vehicleId];
		return (
			v.vehicleId,
			v.filecoinCid,
			v.ownerAddress,
			v.baseHourFee,
			v.bondRequired
		);
	}

	/**
	 * @dev Return a list of rental contract addresses belonging to a particular vehicle owner or renter
	 */
	function getRentalContractsByUser(bool _isOwner, address _address)
		external
		view
		returns (address[] memory)
	{
		if (_isOwner) {
			return ownerToAgreementsAddresses[_address];
		} else {
			return renterToAgreementsAddresses[_address];
		}
	}

	/**
	 * @dev Function to end provider contract, in case of bugs or needing to update logic etc, funds are returned to dapp owner, including any remaining LINK tokens
	 */
	function endContractProvider() external payable onlyOwner {
		LinkTokenInterface link = LinkTokenInterface(LINK_TOKEN);
		link.transfer(msg.sender, link.balanceOf(address(this)));
		selfdestruct(payable(owner()));
	}
}
