import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  stages: [
    { duration: "1m", target: 30 },
    { duration: "3m", target: 30 },
    { duration: "1m", target: 0 },
  ],
};

const BASE_URL = __ENV.BASE_URL || "http://oficina-api.oficina.svc.cluster.local";
const TOKEN = __ENV.TOKEN;

export default function () {
  const cabecalhos = TOKEN ? { headers: { Authorization: `Bearer ${TOKEN}` } } : {};
  const resposta = TOKEN
    ? http.get(`${BASE_URL}/api/ordens`, cabecalhos)
    : http.get(`${BASE_URL}/actuator/health`);
  check(resposta, { "status 200": (r) => r.status === 200 });
  sleep(0.2);
}
