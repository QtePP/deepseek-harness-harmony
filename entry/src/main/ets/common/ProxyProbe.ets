import { connection } from '@kit.NetworkKit'

export class ProxyProbe {
  static async local(): Promise<string> {
    try {
      const p = await connection.getDefaultHttpProxy()
      if (p === undefined || p.host === undefined || p.host.length === 0) return ''
      if (p.exclusionList !== undefined && p.exclusionList.length === 1 && p.exclusionList[0] === '*') return ''
      return `http://${p.host}:${p.port}`
    } catch (error) {
      return ''
    }
  }
}
