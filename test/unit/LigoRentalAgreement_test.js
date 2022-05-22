const { expect } = require("chai");
const { ethers, waffle } = require("hardhat");
const { secondsSinceEpoch } = require("../../scripts/helper-scripts");

describe("LigoRentalAgreement Constructor Unit Test", () => {
  it("Should deploy contract successfully", async () => {
    // Arrange
    const [parent, owner, renter] = await ethers.getSigners();
    const deployementData = {
      vehicleOwner: owner.address,
      renter: renter.address,
      vehicleId: "65bf2263-d5c9-4e3e-b893-550ef9d0b27e",
      startDateTime: secondsSinceEpoch() + 60,
      endDateTime: secondsSinceEpoch() + 60 * 60,
      totalRentCost: ethers.utils.parseEther("0.1"),
      bondRequired: ethers.utils.parseEther("0.1"),
      linkToken: "0xa36085F69e2889c224210F603D836748e7dC0088",
      oracleContract: "0x89dca850F3C3BF8fB0209190CD45e4a59632C73D",
      oraclePayment: 0,
      jobId:
        "0x3635663236636336396665323435346561636631323961656638343665363561", //"65f26cc69fe2454eacf129aef846e65a", // "65f26cc69fe2454eacf129aef846e65a",
    };

    const LigoRentalAgreement = await ethers.getContractFactory(
      "LigoRentalAgreement"
    );
    const provider = waffle.provider;

    // Act
    ligoAgreement = await LigoRentalAgreement.deploy(deployementData, {
      value: ethers.utils.parseEther("0.2"),
    });
    await ligoAgreement.deployed();
    const contractBalance = await provider.getBalance(ligoAgreement.address);
    const getDetails = await ligoAgreement.getAgreementDetails();

    // Assert
    expect(String(contractBalance)).to.equal(
      ethers.utils.parseEther("0.2").toString()
    );
    expect(getDetails[6]).to.equal(0); // PROPOSED
  });

  it("Shouldn't deploy contract", async () => {
    // Arrange
    const [parent, owner, renter] = await ethers.getSigners();
    const deployementData = {
      vehicleOwner: owner.address,
      renter: renter.address,
      vehicleId: "65bf2263-d5c9-4e3e-b893-550ef9d0b27e",
      startDateTime: secondsSinceEpoch() + 60,
      endDateTime: secondsSinceEpoch() + 60 * 60,
      totalRentCost: ethers.utils.parseEther("0.1"),
      bondRequired: ethers.utils.parseEther("0.1"),
      linkToken: "0xa36085F69e2889c224210F603D836748e7dC0088",
      oracleContract: "0x89dca850F3C3BF8fB0209190CD45e4a59632C73D",
      oraclePayment: 0,
      jobId:
        "0x3635663236636336396665323435346561636631323961656638343665363561", //"65f26cc69fe2454eacf129aef846e65a", // "65f26cc69fe2454eacf129aef846e65a",
    };

    const LigoRentalAgreement = await ethers.getContractFactory(
      "LigoRentalAgreement"
    );

    // Act & Assert
    await expect(
      LigoRentalAgreement.deploy(deployementData, {
        value: ethers.utils.parseEther("0.19"),
      })
    ).to.be.reverted;
  });
});

describe("LigoRentalAgreement Functions Unit Test", () => {
  let parentContract, vehicleOwner, renter;
  let ligoAgreement;

  const approveAgreementContract = async () => {
    const transaction = await ligoAgreement
      .connect(vehicleOwner)
      .approveContract();
    await transaction.wait();
  };

  const rejectAgreementContract = async () => {
    const transaction = await ligoAgreement
      .connect(vehicleOwner)
      .rejectContract();
    await transaction.wait();
  };

  beforeEach(async () => {
    [parentContract, vehicleOwner, renter] = await ethers.getSigners();

    const deployementData = {
      vehicleOwner: vehicleOwner.address,
      renter: renter.address,
      vehicleId: "65bf2263-d5c9-4e3e-b893-550ef9d0b27e",
      startDateTime: secondsSinceEpoch() + 60,
      endDateTime: secondsSinceEpoch() + 60 * 60,
      totalRentCost: ethers.utils.parseEther("0.1"),
      bondRequired: ethers.utils.parseEther("0.1"),
      linkToken: "0xa36085F69e2889c224210F603D836748e7dC0088",
      oracleContract: "0x89dca850F3C3BF8fB0209190CD45e4a59632C73D",
      oraclePayment: 0,
      jobId:
        "0x3635663236636336396665323435346561636631323961656638343665363561", //"65f26cc69fe2454eacf129aef846e65a", // "65f26cc69fe2454eacf129aef846e65a",
    };

    const LigoRentalAgreement = await ethers.getContractFactory(
      "LigoRentalAgreement"
    );
    ligoAgreement = await LigoRentalAgreement.deploy(deployementData, {
      value: ethers.utils.parseEther("0.2"),
    });
    await ligoAgreement.deployed();
  });

  it("Should run approveContract(), change agreements status", async () => {
    // Arrange & Act
    approveAgreementContract();
    getDetails = await ligoAgreement
      .connect(vehicleOwner)
      .getAgreementDetails();

    // Assert
    expect(getDetails[6]).to.equal(1); //APPROVED
  });

  //   it("Should run rejectContract(), transfer renter ETH, LINK and change status", async () => {
  //     // Arrange
  //     const provider = waffle.provider;

  //     //Act
  //     rejectAgreementContract();
  //     getDetails = await ligoAgreement
  //       .connect(vehicleOwner)
  //       .getAgreementDetails();
  //     const contractBalance = await provider.getBalance(ligoAgreement.address);

  //     // Assert
  //     // expect(contractBalance).to.equal(0);
  //     expect(getDetails[6]).to.equal(2); //REJECTED
  //   });
});
