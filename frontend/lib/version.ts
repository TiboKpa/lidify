import packageJson from "../package.json";

// Base version from package.json
const BASE_VERSION = packageJson.version;

// Check if this is a nightly build (set via NEXT_PUBLIC_BUILD_TYPE env var)
const isNightly = process.env.NEXT_PUBLIC_BUILD_TYPE === "nightly";

// Export version with nightly suffix if applicable
export const APP_VERSION = isNightly ? `${BASE_VERSION}-nightly` : BASE_VERSION;
