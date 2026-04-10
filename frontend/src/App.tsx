import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { Layout } from "./components/Layout";
import { ToastProvider } from "./components/Toast";
import { AboutPage } from "./pages/About";
import { PoolsPage } from "./pages/Pools";
import { PortfolioPage } from "./pages/Portfolio";
import { ProtocolPage } from "./pages/Protocol";
import { SwapPage } from "./pages/Swap";
import { WalletProvider } from "./wallet/Provider";

export function App() {
  return (
    <WalletProvider>
      <ToastProvider>
        <BrowserRouter>
          <Routes>
            <Route element={<Layout />}>
              <Route index element={<SwapPage />} />
              <Route path="pools" element={<PoolsPage />} />
              <Route path="portfolio" element={<PortfolioPage />} />
              <Route path="protocol" element={<ProtocolPage />} />
              <Route path="about" element={<AboutPage />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Route>
          </Routes>
        </BrowserRouter>
      </ToastProvider>
    </WalletProvider>
  );
}
