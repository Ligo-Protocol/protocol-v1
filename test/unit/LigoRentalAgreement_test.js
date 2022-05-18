const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LigoRentalAgreement Unit Test", () => {
  before(async () => {
    const LigoRentalAgreement = await ethers.getContractFactory(
      "LigoRentalAgreement"
    );
    const ligoRentalAgreement = await LigoRentalAgreement.deploy();
    await ligoRentalAgreement.deployed();
  });
});
