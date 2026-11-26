import User from "../types/user.type";

/**
 * Perfis com permissão de leitura administrativa.
 *
 * Auditor vê as mesmas telas do admin, mas a UI esconde toda ação de escrita;
 * o backend garante a separação nos endpoints.
 */
const isAdminOrAuditor = (user: User | null | undefined): boolean =>
  !!user && (user.isAdmin || user.role === "auditor" || user.role === "admin");

/** Somente administradores podem criar, editar, desativar ou excluir registros. */
export const isAdminUser = (user: User | null | undefined): boolean =>
  !!user && (user.isAdmin === true || user.role === "admin");

/** Auditor: acesso total em modo somente leitura. */
export const isAuditorUser = (user: User | null | undefined): boolean =>
  !!user && user.role === "auditor" && user.isAdmin !== true;

export default isAdminOrAuditor;
