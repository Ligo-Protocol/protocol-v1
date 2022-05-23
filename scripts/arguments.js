require("dotenv").config();

module.exports = [
  {
    vehicleOwner: process.env.ACCOUNT_1_ADDRESS,
    renter: process.env.ACCOUNT_2_ADDRESS,
    vehicleId: "65bf2263-d5c9-4e3e-b893-550ef9d0b27e",
    startDateTime: 1653332880,
    endDateTime: 1653336480,
    totalRentCost: "10000000000000000",
    bondRequired: "10000000000000000",
    linkToken: "0xa36085F69e2889c224210F603D836748e7dC0088",
    oracleContract: "0x89dca850F3C3BF8fB0209190CD45e4a59632C73D",
    oraclePayment: 0,
    jobId: "0x3635663236636336396665323435346561636631323961656638343665363561",
  },
];
