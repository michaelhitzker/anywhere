import { hostname } from "node:os";
import { Bonjour } from "bonjour-service";

export const companionBonjourType = "anywhere-bridge";

export interface CompanionBonjourAdvertiser {
  stop(): Promise<void>;
}

export function startCompanionBonjourAdvertiser(port: number): CompanionBonjourAdvertiser {
  const bonjour = new Bonjour({}, (error: unknown) => {
    console.warn("[bonjour]", error);
  });

  const service = bonjour.publish({
    name: `Anywhere Bridge on ${hostname()}`,
    type: companionBonjourType,
    port,
    protocol: "tcp",
    txt: {
      path: "/",
      service: "anywhere-bridge"
    }
  });

  service.on("error", (error) => {
    console.warn("[bonjour]", error);
  });

  return {
    stop() {
      return new Promise((resolve) => {
        const stopService = service.stop?.bind(service);
        if (!stopService) {
          bonjour.destroy(() => resolve());
          return;
        }

        stopService(() => {
          bonjour.destroy(() => resolve());
        });
      });
    }
  };
}
