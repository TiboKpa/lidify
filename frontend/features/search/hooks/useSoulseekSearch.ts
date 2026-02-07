import { useState, useEffect, useCallback } from "react";
import { api } from "@/lib/api";
import { toast } from "sonner";
import type { SoulseekResult } from "../types";

interface UseSoulseekSearchProps {
    query: string;
}

interface UseSoulseekSearchReturn {
    soulseekResults: SoulseekResult[];
    isSoulseekSearching: boolean;
    isSoulseekPolling: boolean;
    soulseekEnabled: boolean;
    downloadingFiles: Set<string>;
    handleDownload: (result: SoulseekResult) => Promise<void>;
}

export function useSoulseekSearch({
    query,
}: UseSoulseekSearchProps): UseSoulseekSearchReturn {
    const [soulseekResults, setSoulseekResults] = useState<SoulseekResult[]>(
        [],
    );
    const [isSoulseekSearching, setIsSoulseekSearching] = useState(false);
    const [isSoulseekPolling, setIsSoulseekPolling] = useState(false);
    const [, setSoulseekSearchId] = useState<string | null>(
        null,
    );
    const [soulseekEnabled, setSoulseekEnabled] = useState(false);
    const [downloadingFiles, setDownloadingFiles] = useState<Set<string>>(
        new Set(),
    );

    // Check if Soulseek is configured (has credentials)
    // Use the public /soulseek/status endpoint instead of admin-only /system-settings
    useEffect(() => {
        const checkSoulseekStatus = async () => {
            try {
                const status = await api.getSlskdStatus();
                // The status endpoint returns { enabled: boolean, connected: boolean }
                setSoulseekEnabled(Boolean(status.enabled));
            } catch (error) {
                console.error("Failed to check Soulseek status:", error);
                setSoulseekEnabled(false);
            }
        };

        checkSoulseekStatus();
    }, []);

    // Soulseek search with polling
    useEffect(() => {
        if (!query.trim() || !soulseekEnabled) {
            setSoulseekResults([]);
            setSoulseekSearchId(null);
            return;
        }

        let pollInterval: NodeJS.Timeout | null = null;

        const timer = setTimeout(async () => {
            setIsSoulseekSearching(true);
            setIsSoulseekPolling(true);

            try {
                const { searchId } = await api.searchSoulseek(query);
                setSoulseekSearchId(searchId);
                setSoulseekResults([]);

                // Poll for results - Soulseek search takes ~45 seconds to complete
                // Poll for up to 60 seconds to ensure we catch results
                let pollCount = 0;
                const maxPolls = 30; // 30 polls * 2s = 60 seconds max

                // Wait 3 seconds before starting to poll (give search time to start collecting)
                await new Promise((resolve) => setTimeout(resolve, 3000));
                setIsSoulseekSearching(false); // Initial search request complete

                pollInterval = setInterval(async () => {
                    try {
                        const { results } =
                            await api.getSoulseekResults(searchId);

                        if (results && results.length > 0) {
                            setSoulseekResults(results);
                            // If we have enough results, we can stop polling early
                            if (results.length >= 10) {
                                if (pollInterval) clearInterval(pollInterval);
                                setIsSoulseekPolling(false);
                            }
                        }

                        pollCount++;

                        if (pollCount >= maxPolls) {
                            if (pollInterval) clearInterval(pollInterval);
                            setIsSoulseekPolling(false);
                        }
                    } catch (error) {
                        console.error("Error polling Soulseek results:", error);
                        if (pollInterval) clearInterval(pollInterval);
                        setIsSoulseekPolling(false);
                    }
                }, 2000);
            } catch (error) {
                console.error("Soulseek search error:", error);
                if (
                    error instanceof Error &&
                    error.message?.includes("not enabled")
                ) {
                    setSoulseekEnabled(false);
                }
                setIsSoulseekSearching(false);
                setIsSoulseekPolling(false);
            }
        }, 800);

        return () => {
            clearTimeout(timer);
            if (pollInterval) {
                clearInterval(pollInterval);
            }
            setIsSoulseekPolling(false);
        };
    }, [query, soulseekEnabled]);

    // Handle downloads
    const handleDownload = useCallback(async (result: SoulseekResult) => {
        try {
            setDownloadingFiles((prev) => new Set([...prev, result.filename]));

            await api.downloadFromSoulseek(
                result.username,
                result.path,
                result.filename,
                result.size,
                result.parsedArtist,
                result.parsedAlbum,
                result.parsedTitle,
            );

            // Use the activity sidebar (Active tab) instead of a toast/modal
            if (typeof window !== "undefined") {
                window.dispatchEvent(
                    new CustomEvent("set-activity-panel-tab", {
                        detail: { tab: "active" },
                    }),
                );
                window.dispatchEvent(new CustomEvent("open-activity-panel"));
                window.dispatchEvent(new CustomEvent("notifications-changed"));
            }

            setTimeout(() => {
                setDownloadingFiles((prev) => {
                    const newSet = new Set(prev);
                    newSet.delete(result.filename);
                    return newSet;
                });
            }, 5000);
        } catch (error) {
            console.error("Download error:", error);
            const message =
                error instanceof Error ?
                    error.message
                :   "Failed to start download";
            toast.error(message);
            setDownloadingFiles((prev) => {
                const newSet = new Set(prev);
                newSet.delete(result.filename);
                return newSet;
            });
        }
    }, []);

    return {
        soulseekResults,
        isSoulseekSearching,
        isSoulseekPolling,
        soulseekEnabled,
        downloadingFiles,
        handleDownload,
    };
}
