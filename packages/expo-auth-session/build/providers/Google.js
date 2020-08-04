import * as Application from 'expo-application';
import Constants from 'expo-constants';
import { useMemo } from 'react';
import { Platform } from 'react-native';
import { useAuthRequestResult, useLoadedAuthRequest } from '../AuthRequestHooks';
import { AuthRequest, generateHexStringAsync, makeRedirectUri, Prompt, ResponseType, } from '../AuthSession';
const settings = {
    windowFeatures: { width: 515, height: 680 },
    minimumScopes: [
        'openid',
        'https://www.googleapis.com/auth/userinfo.profile',
        'https://www.googleapis.com/auth/userinfo.email',
    ],
};
export const discovery = {
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
    revocationEndpoint: 'https://oauth2.googleapis.com/revoke',
    userInfoEndpoint: 'https://openidconnect.googleapis.com/v1/userinfo',
};
function applyRequiredScopes(scopes = []) {
    // Add the required scopes for returning profile data.
    const requiredScopes = [...scopes, ...settings.minimumScopes];
    // Remove duplicates
    return [...new Set(requiredScopes)];
}
class GoogleAuthRequest extends AuthRequest {
    constructor({ language, loginHint, selectAccount, extraParams = {}, clientSecret, ...config }) {
        const inputParams = {
            ...extraParams,
        };
        if (language)
            inputParams.hl = language;
        if (loginHint)
            inputParams.login_hint = loginHint;
        if (selectAccount)
            inputParams.prompt = Prompt.SelectAccount;
        // Apply the default scopes
        const scopes = applyRequiredScopes(config.scopes);
        const isImplicit = config.responseType === ResponseType.Token || config.responseType === ResponseType.IdToken;
        if (isImplicit) {
            // PKCE must be disabled in implicit mode.
            config.usePKCE = false;
        }
        let inputClientSecret;
        //  Google will throw if you attempt to use the client secret
        if (config.responseType && config.responseType !== ResponseType.Code) {
            // TODO: maybe warn that you shouldn't store the client secret on the client
            inputClientSecret = clientSecret;
        }
        super({
            ...config,
            clientSecret: inputClientSecret,
            scopes,
            extraParams: inputParams,
        });
    }
    /**
     * Load and return a valid auth request based on the input config.
     */
    async getAuthRequestConfigAsync() {
        const { extraParams = {}, ...config } = await super.getAuthRequestConfigAsync();
        if (config.responseType === ResponseType.IdToken && !extraParams.nonce && !this.nonce) {
            if (!this.nonce) {
                this.nonce = await generateHexStringAsync(16);
            }
            extraParams.nonce = this.nonce;
        }
        return {
            ...config,
            extraParams,
        };
    }
}
// Only natively in the Expo client.
function shouldUseProxy() {
    return Platform.select({
        web: false,
        // Use the proxy in the Expo client.
        default: !!Constants.manifest && Constants.appOwnership !== 'standalone',
    });
}
function invariantClientId(idName, value) {
    if (typeof value === 'undefined')
        // TODO(Bacon): Add learn more
        throw new Error(`Client Id property \`${idName}\` must be defined to use Google auth on this platform.`);
}
/**
 * Load an authorization request.
 * Returns a loaded request, a response, and a prompt method.
 * When the prompt method completes then the response will be fulfilled.
 *
 * - [Get Started](https://docs.expo.io/guides/authentication/#google)
 *
 * @param config
 * @param discovery
 */
export function useAuthRequest(config = {}, redirectUriOptions = {}) {
    const useProxy = useMemo(() => redirectUriOptions.useProxy ?? shouldUseProxy(), [
        redirectUriOptions.useProxy,
    ]);
    const clientId = useMemo(() => {
        const propertyName = useProxy
            ? 'expoClientId'
            : Platform.select({
                ios: 'iosClientId',
                android: 'androidClientId',
                default: 'webClientId',
            });
        const clientId = config[propertyName] ?? config.clientId;
        invariantClientId(propertyName, clientId);
        return clientId;
    }, [
        useProxy,
        config.expoClientId,
        config.iosClientId,
        config.androidClientId,
        config.webClientId,
        config.clientId,
    ]);
    const redirectUri = useMemo(() => {
        if (typeof config.redirectUri !== 'undefined') {
            return config.redirectUri;
        }
        return makeRedirectUri({
            native: `${Application.applicationId}:/oauthredirect`,
            useProxy,
            ...redirectUriOptions,
        });
    }, [useProxy, config.redirectUri, redirectUriOptions]);
    const extraParams = useMemo(() => {
        const output = config.extraParams ? { ...config.extraParams } : {};
        if (config.language) {
            output.hl = output.language;
        }
        if (config.loginHint) {
            output.login_hint = output.loginHint;
        }
        if (config.selectAccount) {
            output.prompt = Prompt.SelectAccount;
        }
        return output;
    }, [config.extraParams, config.language, config.loginHint, config.selectAccount]);
    const request = useLoadedAuthRequest({
        ...config,
        extraParams,
        clientId,
        redirectUri,
    }, discovery, GoogleAuthRequest);
    const [result, promptAsync] = useAuthRequestResult(request, discovery, {
        useProxy,
        windowFeatures: settings.windowFeatures,
    });
    return [request, result, promptAsync];
}
//# sourceMappingURL=Google.js.map