// server.js
const express = require("express");
const app = express();
const PORT = process.env.PORT || 8080;

// Middleware to parse JSON
app.use(express.json());

// Sample route
app.get("/", (req, res) => {
  res.send("Hello from Express + Docker!");
});

// Another route
app.post("/echo", (req, res) => {
  res.json({
    received: req.body,
  });
});

app.listen(PORT, () => {
  console.log(`🚀 Server is running on port ${PORT}`);
});

