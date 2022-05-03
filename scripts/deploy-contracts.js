const hre = require("hardhat");

async function main() {
    // Hardhat always runs the compile task when running scripts with its command
    // line interface.
    //
    // If this script is run directly using `node` you may want to call compile
    // manually to make sure everything is compiled
    // await hre.run('compile');

    // We get the contract to deploy
    const LigoContract = await hre.ethers.getContractFactory("LigoContract");
    const ligoContract = await LigoContract.deploy();

    await ligoContract.deployed();

    console.log("Deployed to:", ligoContract.address);
    await ligoContract.getSender();
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
