const express = require('express');
const { Pool } = require('pg');
const path = require('path');

const app = express();
app.use(express.json());
app.use(express.static(__dirname));

// 🔌 Connect to PostgreSQL
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'hobbydb',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
});

// 🏗️ Create table — retry until Postgres is ready
async function setupDB(retries = 10) {
  for (let i = 1; i <= retries; i++) {
    try {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS users (
          id SERIAL PRIMARY KEY,
          name TEXT NOT NULL,
          hobby TEXT NOT NULL
        )
      `);
      console.log('✅ Table is ready!');
      return;
    } catch (err) {
      console.log(`⏳ Waiting for database... (attempt ${i}/${retries})`);
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  throw new Error('❌ Could not connect to database after several attempts.');
}

// ➕ Add name + hobby
app.post('/add', async (req, res) => {
  const { name, hobby } = req.body;
  if (!name || !hobby) return res.status(400).json({ error: 'Name and hobby are required!' });

  await pool.query('INSERT INTO users (name, hobby) VALUES ($1, $2)', [name, hobby]);
  res.json({ message: `🎉 Saved! ${name} loves ${hobby}` });
});

// 🔍 Find hobby by name
app.get('/find', async (req, res) => {
  const { name } = req.query;
  if (!name) return res.status(400).json({ error: 'Please provide a name!' });

  const result = await pool.query('SELECT hobby FROM users WHERE LOWER(name) = LOWER($1)', [name]);
  if (result.rows.length === 0) return res.json({ message: `😕 No one named "${name}" found.` });

  const hobbies = result.rows.map(r => r.hobby).join(', ');
  res.json({ message: `🎯 ${name}'s hobby: ${hobbies}` });
});

// 🚀 Start
setupDB().then(() => {
  app.listen(3000, () => console.log('🌟 App running at http://localhost:3000'));
});
