from langflow.custom import Component
from langflow.io import (
    MessageTextInput,
    SecretStrInput,
    IntInput,
    Output,
)
from langflow.schema import Data

from pinecone import Pinecone
from openai import OpenAI


class PineconeSearchMultiNamespaceComponent(Component):
    display_name = "Pinecone Search (Multi-namespace)"
    description = (
        "Performs semantic similarity search in Pinecone"
    )
    icon = "Pinecone"
    name = "PineconeSearchMultiNamespace"

    inputs = [
        SecretStrInput(name="pinecone_api_key", display_name="Clave API de Pinecone", required=True),
        MessageTextInput(name="index_name", display_name="Nombre de índice", value="langflow", required=True),
        SecretStrInput(name="openai_api_key", display_name="OpenAI API Key", required=True),
        MessageTextInput(name="embedding_model", display_name="Modelo de embeddings", value="text-embedding-3-small", required=True),
        MessageTextInput(
            name="search_query",
            display_name="Search Query",
            info="La consulta de búsqueda en lenguaje natural (se usa igual para las 3 áreas).",
            tool_mode=True,
            required=True,
        ),
        MessageTextInput(
            name="namespaces",
            display_name="Namespaces",
            info=(
                "Lista de 1 a 3 namespaces separados por coma, sin espacios, EXACTOS "
                "(mayúsculas y guiones bajos incluidos)."
            ),
            tool_mode=True,
            required=True,
        ),
        IntInput(name="top_k", display_name="Número de resultados por área", value=4),
    ]

    outputs = [
        Output(display_name="Resultados", name="results", method="search"),
    ]

    def search(self) -> Data:
        # 1. Generar el embedding UNA sola vez (se reutiliza para las 3 búsquedas)
        openai_client = OpenAI(api_key=self.openai_api_key)
        embedding_response = openai_client.embeddings.create(
            model=self.embedding_model,
            input=self.search_query,
        )
        query_vector = embedding_response.data[0].embedding

        # 2. Parsear la lista de namespaces
        namespace_list = [ns.strip() for ns in self.namespaces.split(",") if ns.strip()]

        # 3. Consultar Pinecone en cada namespace, reutilizando el mismo vector
        pc = Pinecone(api_key=self.pinecone_api_key)
        index = pc.Index(self.index_name)

        resultados_por_area = {}
        for namespace in namespace_list:
            query_response = index.query(
                vector=query_vector,
                top_k=self.top_k,
                namespace=namespace,
                include_metadata=True,
            )
            matches = []
            for match in query_response.get("matches", []):
                metadata = match.get("metadata", {})
                matches.append({
                    "score": match.get("score"),
                    "text": metadata.get("text", ""),
                })
            resultados_por_area[namespace] = matches

        result_data = Data(
            data={
                "query": self.search_query,
                "resultados_por_area": resultados_por_area,
            }
        )
        self.status = result_data
        return result_data
