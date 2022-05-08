//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract LigoAgreementsFactory is Ownable {

    /**
     * @dev Return a vehicle ID for a given vehicle address
     */  
    function getVehicleId(address _vehicleAddress) public view returns (uint) {
        // TODO: update return value
        return uint(1);
    }    

}