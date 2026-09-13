import http from "k6/http";
import { sleep } from "k6";

// Gera carga crescente para demonstrar o scale-up/scale-down do HPA.
export const options = {
  stages: [
    { duration: "1m", target: 50 },
    { duration: "3m", target: 50 },
    { duration: "1m", target: 0 },
  ],
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

export default function () {
  http.get(`${BASE_URL}/actuator/health`);
  sleep(0.2);
}
