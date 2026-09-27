const assert = require('node:assert/strict');
const response = {ok: true};
const calls = [];
global.fetch = async (url, init) => {calls.push({url, init}); return response};
(async () => {
  const {submitRefund} = require('./client.js');
  const payload = {id:'independent-payment', amountMinor:250};
  assert.equal(await submitRefund(payload), response);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://vendor.example/v1/refunds');
  assert.equal(calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(calls[0].init.body), payload);
  console.log(JSON.stringify({passed:true,cases:['refund route','POST method','payload','response']}));
})().catch(error => {console.log(JSON.stringify({passed:false,error:error.message}));process.exitCode=1});
