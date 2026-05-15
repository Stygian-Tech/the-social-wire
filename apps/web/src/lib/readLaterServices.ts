export const READ_LATER_SERVICES = [
  {
    id: "latr-link",
    label: "L@tr.link",
    connected: true,
    loginLabel: null,
    loginUrl: null,
  },
  {
    id: "instapaper",
    label: "Instapaper",
    connected: false,
    loginLabel: "Log In To Instapaper",
    loginUrl: "https://www.instapaper.com/user/login",
  },
  {
    id: "omnivore",
    label: "Omnivore",
    connected: false,
    loginLabel: "Log In To Omnivore",
    loginUrl: "https://omnivore.app/login",
  },
  {
    id: "readwise-reader",
    label: "Readwise Reader",
    connected: false,
    loginLabel: "Log In To Readwise Reader",
    loginUrl: "https://read.readwise.io/",
  },
  {
    id: "raindrop",
    label: "Raindrop.io",
    connected: false,
    loginLabel: "Log In To Raindrop.io",
    loginUrl: "https://app.raindrop.io/",
  },
] as const;

export type ReadLaterServiceId = (typeof READ_LATER_SERVICES)[number]["id"];

export const READ_LATER_SERVICE_STORAGE_KEY =
  "social-wire.saved.read-later-service";

export function findReadLaterService(serviceId: string | null | undefined) {
  return (
    READ_LATER_SERVICES.find((service) => service.id === serviceId) ??
    READ_LATER_SERVICES[0]
  );
}
