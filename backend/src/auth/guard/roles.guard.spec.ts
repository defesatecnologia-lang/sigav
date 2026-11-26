import { ExecutionContext } from "@nestjs/common";
import { Reflector } from "@nestjs/core";
import { RolesGuard } from "./roles.guard";

describe("RolesGuard — matriz admin/auditor/operador", () => {
  function makeGuard(requiredRoles?: string[]) {
    const reflector = {
      getAllAndOverride: jest.fn().mockReturnValue(requiredRoles),
    } as unknown as Reflector;
    return new RolesGuard(reflector);
  }

  function makeContext(user?: { role?: string; isAdmin?: boolean }) {
    const request = user === undefined ? {} : { user };
    return {
      getHandler: () => ({}),
      getClass: () => ({}),
      switchToHttp: () => ({ getRequest: () => request }),
    } as unknown as ExecutionContext;
  }

  it("permite qualquer usuário autenticado quando não há @Roles", () => {
    const guard = makeGuard();
    expect(guard.canActivate(makeContext({ role: "operador" }))).toBe(true);
  });

  it("nega acesso sem usuário autenticado", () => {
    const guard = makeGuard(["admin", "auditor"]);
    expect(guard.canActivate(makeContext())).toBe(false);
  });

  it.each(["admin", "auditor"])(
    "permite %s em endpoints de leitura (@Roles('admin','auditor'))",
    (role) => {
      const guard = makeGuard(["admin", "auditor"]);
      expect(guard.canActivate(makeContext({ role, isAdmin: role === "admin" }))).toBe(true);
    },
  );

  it("nega operador em endpoints de leitura administrativa", () => {
    const guard = makeGuard(["admin", "auditor"]);
    expect(guard.canActivate(makeContext({ role: "operador" }))).toBe(false);
  });

  it("nega auditor em endpoints de escrita (@Roles('admin'))", () => {
    const guard = makeGuard(["admin"]);
    expect(guard.canActivate(makeContext({ role: "auditor" }))).toBe(false);
  });

  it("nega auditor mesmo se o campo legado isAdmin estiver divergente", () => {
    const guard = makeGuard(["admin"]);
    expect(
      guard.canActivate(makeContext({ role: "auditor", isAdmin: true })),
    ).toBe(false);
  });

  it("permite admin em endpoints de escrita", () => {
    const guard = makeGuard(["admin"]);
    expect(guard.canActivate(makeContext({ role: "admin", isAdmin: true }))).toBe(true);
  });
});
