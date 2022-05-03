//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract LigoRentalAgreement is Ownable {    
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
    
}

// Add events